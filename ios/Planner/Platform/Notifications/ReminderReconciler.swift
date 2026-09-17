import Foundation
import Observation
import PowerSync
import UIKit
import UserNotifications

/// Keeps the pending local notifications equal to the desired set (03_iOS/03_Notifications_EventKit_Widgets.md §1):
/// 14 days, 50 requests, one request per occurrence, no burst for past reminders. Only what iOS reports as pending
/// counts as "programmé".
@Observable
final class ReminderReconciler {
    /// State of each notification identifier after the last pass.
    private(set) var states: [String: ReminderMath.State] = [:]
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let db: any PowerSyncDatabaseProtocol
    @ObservationIgnored private var pass: Task<Void, Never>?
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(db: any PowerSyncDatabaseProtocol) {
        self.db = db
    }

    nonisolated static let category = "TASK_REMINDER"
    nonisolated static let completeAction = "COMPLETE"

    func start() {
        stop()
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [UNNotificationAction(identifier: Self.completeAction, title: "Terminé", options: [])],
                intentIdentifiers: [],
                options: []
            ),
        ])
        let db = self.db
        // Any change of a task, an occurrence or a reminder (manual, assistant, replication) or a sync
        // rejection (the projection is rolled back) triggers a pass.
        listeners.append(Task { [weak self] in
            do {
                let stream = try db.watch(
                    sql: """
                    SELECT (SELECT count(*) FROM tasks) AS tasks, (SELECT count(*) FROM reminders) AS reminders,
                           (SELECT count(*) FROM sync_rejections) AS rejections, (SELECT max(updated_at) FROM tasks) AS task_change,
                           (SELECT max(updated_at) FROM task_occurrences) AS occurrence_change,
                           (SELECT max(updated_at) FROM reminders) AS reminder_change
                    """,
                    parameters: []
                ) { cursor in
                    [
                        String(cursor.getIntOptional(index: 0) ?? 0), String(cursor.getIntOptional(index: 1) ?? 0),
                        String(cursor.getIntOptional(index: 2) ?? 0), cursor.getStringOptional(index: 3) ?? "",
                        cursor.getStringOptional(index: 4) ?? "", cursor.getStringOptional(index: 5) ?? "",
                    ].joined(separator: "|")
                }
                for try await _ in stream {
                    self?.requestPass()
                }
            } catch {}
        })
        let names: [Notification.Name] = [.NSSystemTimeZoneDidChange, .NSCalendarDayChanged, UIApplication.significantTimeChangeNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.requestPass() }
            })
        }
        requestPass()
    }

    func stop() {
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    /// Debounced: several changes in a row give one pass.
    func requestPass() {
        pass?.cancel()
        pass = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    /// Asked when the first reminder is created, never at launch (§1.9).
    func requestAuthorizationIfNeeded() async {
        if await Self.authorizationStatus() == .notDetermined {
            await Self.requestAuthorization()
        }
        requestPass()
    }

    /// Everything a reminder shows in the editor: its next occurrence's state.
    func displayState(reminderId: String) -> ReminderMath.State? {
        let prefix = "r:\(reminderId.lowercased()):"
        let own = states.filter { $0.key.hasPrefix(prefix) }
        if own.isEmpty { return nil }
        for preferred in [ReminderMath.State.scheduled, .needsScheduling, .pendingCapacity, .pendingWindow, .notificationsDisabled, .baseMissing, .missed, .displayUnknown, .removed] {
            if own.values.contains(preferred) { return preferred }
        }
        return own.values.first
    }

    // MARK: - Pass

    private func reconcile() async {
        let status = await Self.authorizationStatus()
        authorization = status
        let authorized = [.authorized, .provisional, .ephemeral].contains(status)
        guard let snapshot = try? await Self.loadSnapshot(db) else { return }
        let now = Date()
        let zone = TimeZone.current
        let candidates = Self.candidates(snapshot, now: now, zone: zone)
        let pending = await Self.pendingRequests()
        let acceptances = (try? await Self.loadAcceptances(db)) ?? [:]
        let plan = ReminderMath.plan(
            now: now, zone: zone, authorized: authorized,
            candidates: candidates.map(\.candidate), systemPending: pending, acceptances: acceptances
        )
        if !plan.remove.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: plan.remove)
        }
        var states = plan.states
        let byId = Dictionary(candidates.map { ($0.candidate.notificationId, $0) }, uniquingKeysWith: { first, _ in first })
        var accepted: [(String, Date)] = []
        for request in plan.addOrReplace {
            guard let source = byId[request.notificationId] else { continue }
            if await Self.add(request, source: source) {
                accepted.append((request.notificationId, request.triggerAt))
                states[request.notificationId] = .scheduled
            } else {
                states[request.notificationId] = .needsScheduling
            }
        }
        try? await Self.recordAcceptances(accepted, now: now, in: db)
        self.states = states
    }

    // MARK: - System (plain values only cross the actor boundary)

    nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    nonisolated static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    nonisolated static func pendingRequests() async -> [ReminderMath.Request] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().compactMap { request in
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger, let date = trigger.nextTriggerDate() else { return nil }
            return ReminderMath.Request(notificationId: request.identifier, triggerAt: date)
        }
    }

    nonisolated static func add(_ request: ReminderMath.Request, source: Source) async -> Bool {
        do {
            try await UNUserNotificationCenter.current().add(notification(for: request, source: source))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Data

    nonisolated struct Source: Sendable {
        let candidate: ReminderMath.Candidate
        let taskId: String
        let title: String
        let occurrenceKey: String?
        let body: String
    }

    nonisolated struct Snapshot: Sendable {
        var tasks: [String: TaskItem] = [:]
        var reminders: [ReminderRow] = []
        var occurrences: [String: [OccurrenceRow]] = [:]
    }

    nonisolated static func loadSnapshot(_ db: any PowerSyncDatabaseProtocol) async throws -> Snapshot {
        var snapshot = Snapshot()
        let tasks = try await db.getAll(
            sql: "SELECT \(TaskItem.selectColumns) FROM tasks WHERE id IN (SELECT task_id FROM reminders)",
            parameters: []
        ) { cursor in try TaskItem(row: cursor) }
        snapshot.tasks = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        snapshot.reminders = try await db.getAll(
            sql: "SELECT id, task_id, occurrence_key, kind, offset_minutes, local_time, absolute_date, absolute_time, absolute_time_zone, state FROM reminders",
            parameters: []
        ) { cursor in
            ReminderRow(
                id: try cursor.getString(name: "id"),
                taskId: try cursor.getStringOptional(name: "task_id") ?? "",
                occurrenceKey: try cursor.getStringOptional(name: "occurrence_key"),
                rule: ReminderRule(
                    kind: try cursor.getStringOptional(name: "kind"), offsetMinutes: try cursor.getIntOptional(name: "offset_minutes"),
                    localTime: try cursor.getStringOptional(name: "local_time"), absoluteDate: try cursor.getStringOptional(name: "absolute_date"),
                    absoluteTime: try cursor.getStringOptional(name: "absolute_time"), absoluteZone: try cursor.getStringOptional(name: "absolute_time_zone")
                ) ?? .beforeStart(minutes: 0),
                baseMissing: try cursor.getStringOptional(name: "state") == "inactive_base_missing"
            )
        }
        let rows = try await db.getAll(
            sql: """
            SELECT task_id, occurrence_key, status, completed_at, override_date, override_time, override_time_zone, successor_occurrence_key
            FROM task_occurrences WHERE task_id IN (SELECT task_id FROM reminders)
            """,
            parameters: []
        ) { cursor in
            OccurrenceRow(
                taskId: try cursor.getString(name: "task_id"),
                key: try cursor.getString(name: "occurrence_key"),
                status: OccurrenceStatus(rawValue: try cursor.getStringOptional(name: "status") ?? "") ?? .open,
                completedAt: nil,
                override: TimeValue(
                    date: try cursor.getStringOptional(name: "override_date"),
                    time: try cursor.getStringOptional(name: "override_time"),
                    timeZone: try cursor.getStringOptional(name: "override_time_zone")
                ),
                successorKey: try cursor.getStringOptional(name: "successor_occurrence_key")
            )
        }
        snapshot.occurrences = Dictionary(grouping: rows, by: \.taskId)
        return snapshot
    }

    /// One candidate per reminder, or per open occurrence of a series in the window.
    nonisolated static func candidates(_ snapshot: Snapshot, now: Date, zone: TimeZone) -> [Source] {
        let today = TimeResolver.localDate(at: now, in: zone)
        var sources: [Source] = []
        for reminder in snapshot.reminders {
            guard let task = snapshot.tasks[reminder.taskId] else { continue }
            let live = !task.isDeleted && !task.isCompleted
            if task.isRecurring {
                let rows = snapshot.occurrences[task.id] ?? []
                var items = SeriesCalculator.openOccurrences(task: task, rows: rows, from: today.adding(days: -1), through: today.adding(days: ReminderMath.windowDays + 1), zone: zone)
                if let key = reminder.occurrenceKey { items = items.filter { $0.occurrenceKey == key } }
                for item in items {
                    let key = item.occurrenceKey
                    let trigger = ReminderMath.trigger(reminder.rule, schedule: item.schedule, deadline: nil, deviceZone: zone)
                    sources.append(Source(
                        candidate: .init(notificationId: ReminderMath.notificationId(reminderId: reminder.id, occurrenceKey: key), trigger: trigger, eligible: live),
                        taskId: task.id, title: task.title, occurrenceKey: key, body: body(item.schedule, deadline: nil)
                    ))
                }
            } else {
                let trigger = ReminderMath.trigger(reminder.rule, schedule: task.schedule, deadline: task.deadline, deviceZone: zone)
                sources.append(Source(
                    candidate: .init(notificationId: ReminderMath.notificationId(reminderId: reminder.id, occurrenceKey: nil), trigger: trigger, eligible: live),
                    taskId: task.id, title: task.title, occurrenceKey: nil,
                    body: body(reminder.rule.usesDeadline ? nil : task.schedule, deadline: reminder.rule.usesDeadline ? task.deadline : nil)
                ))
            }
        }
        return sources
    }

    /// Understandable without opening the app; notes are never included.
    nonisolated static func body(_ schedule: TimeValue?, deadline: TimeValue?) -> String {
        let today = CivilDate.today()
        if let deadline { return "Échéance " + DateText.moment(deadline, today: today) }
        if let schedule { return "Prévu " + DateText.moment(schedule, today: today) }
        return "Rappel"
    }

    nonisolated static func notification(for request: ReminderMath.Request, source: Source) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = source.title
        content.body = source.body
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = source.taskId
        content.userInfo = ["taskId": source.taskId, "occurrenceKey": source.occurrenceKey ?? ""]
        // An absolute UTC date: the request keeps its instant when the device changes zone.
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        calendar.timeZone = utc
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: request.triggerAt)
        components.calendar = calendar
        components.timeZone = utc
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: request.notificationId, content: content, trigger: trigger)
    }

    nonisolated static func loadAcceptances(_ db: any PowerSyncDatabaseProtocol) async throws -> [String: (triggerAt: Date, acceptedAt: Date)] {
        let rows = try await db.getAll(sql: "SELECT id, trigger_at, accepted_at FROM scheduled_notifications", parameters: []) { cursor in
            (try cursor.getString(index: 0), Timestamp.parse(cursor.getStringOptional(index: 1)), Timestamp.parse(cursor.getStringOptional(index: 2)))
        }
        var result: [String: (triggerAt: Date, acceptedAt: Date)] = [:]
        for (id, trigger, accepted) in rows {
            if let trigger, let accepted { result[id] = (trigger, accepted) }
        }
        return result
    }

    nonisolated static func recordAcceptances(_ accepted: [(String, Date)], now: Date, in db: any PowerSyncDatabaseProtocol) async throws {
        let rows = accepted.map { ($0.0, Timestamp.format($0.1)) }
        let acceptedAt = Timestamp.format(now)
        let horizon = Timestamp.format(now.addingTimeInterval(-3 * 86_400))
        try await db.writeTransaction { tx in
            for (id, trigger) in rows {
                try tx.execute(sql: "DELETE FROM scheduled_notifications WHERE id = ?", parameters: [id])
                try tx.execute(
                    sql: "INSERT INTO scheduled_notifications (id, trigger_at, accepted_at) VALUES (?, ?, ?)",
                    parameters: [id, trigger, acceptedAt]
                )
            }
            // Proofs of scheduling older than three days are no longer useful.
            try tx.execute(sql: "DELETE FROM scheduled_notifications WHERE trigger_at < ?", parameters: [horizon])
        }
    }
}

/// Notification taps and actions (§1.8): open the task or the occurrence, or complete it with the same
/// command as the UI. The system may call the delegate off the main actor, hence the nonisolated methods.
final class NotificationRouter: NSObject, nonisolated UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    private var openHandler: ((OpenTarget) -> Void)?
    private var completeHandler: ((OpenTarget) async -> Void)?
    /// Actions received before the services are ready (the app was launched by the notification).
    private var waiting: [(target: OpenTarget, complete: Bool)] = []

    func attach(open: @escaping (OpenTarget) -> Void, complete: @escaping (OpenTarget) async -> Void) {
        openHandler = open
        completeHandler = complete
        let queued = waiting
        waiting.removeAll()
        for entry in queued {
            deliver(entry.target, complete: entry.complete)
        }
    }

    func detach() {
        openHandler = nil
        completeHandler = nil
    }

    func deliver(_ target: OpenTarget, complete: Bool) {
        if complete {
            guard let handler = completeHandler else {
                waiting.append((target, true))
                return
            }
            Task { await handler(target) }
        } else {
            guard let handler = openHandler else {
                waiting.append((target, false))
                return
            }
            handler(target)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let taskId = info["taskId"] as? String, !taskId.isEmpty else { return }
        let key = info["occurrenceKey"] as? String ?? ""
        let target = OpenTarget(taskId: taskId, occurrenceKey: key.isEmpty ? nil : key)
        let complete = response.actionIdentifier == ReminderReconciler.completeAction
        await deliver(target, complete: complete)
    }
}
