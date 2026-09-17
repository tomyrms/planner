import Foundation

/// One reminder rule (04_Backend/03_Data_Model.md §3): relative to the planned time or the deadline,
/// at a time on the planned or due day, or absolute.
nonisolated enum ReminderRule: Hashable, Sendable {
    case beforeStart(minutes: Int)
    case beforeDeadline(minutes: Int)
    case onScheduledDay(LocalTime)
    case onDeadlineDay(LocalTime)
    case absolute(TimeValue)

    init?(kind: String?, offsetMinutes: Int?, localTime: String?, absoluteDate: String?, absoluteTime: String?, absoluteZone: String?) {
        switch kind {
        case "before_start": guard let offsetMinutes else { return nil }; self = .beforeStart(minutes: offsetMinutes)
        case "before_deadline": guard let offsetMinutes else { return nil }; self = .beforeDeadline(minutes: offsetMinutes)
        case "on_scheduled_day_at": guard let time = LocalTime(localTime) else { return nil }; self = .onScheduledDay(time)
        case "on_deadline_day_at": guard let time = LocalTime(localTime) else { return nil }; self = .onDeadlineDay(time)
        case "absolute":
            guard let value = TimeValue(date: absoluteDate, time: absoluteTime, timeZone: absoluteZone), value.time != nil else { return nil }
            self = .absolute(value)
        default: return nil
        }
    }

    var kind: String {
        switch self {
        case .beforeStart: "before_start"
        case .beforeDeadline: "before_deadline"
        case .onScheduledDay: "on_scheduled_day_at"
        case .onDeadlineDay: "on_deadline_day_at"
        case .absolute: "absolute"
        }
    }

    /// `rule` of `reminder.set`.
    var payload: JSONPayload {
        switch self {
        case .beforeStart(let minutes): ["kind": "before_start", "offsetMinutes": .int(minutes)]
        case .beforeDeadline(let minutes): ["kind": "before_deadline", "offsetMinutes": .int(minutes)]
        case .onScheduledDay(let time): ["kind": "on_scheduled_day_at", "localTime": .string(time.description)]
        case .onDeadlineDay(let time): ["kind": "on_deadline_day_at", "localTime": .string(time.description)]
        case .absolute(let value): ["kind": "absolute", "absolute": value.payload]
        }
    }

    /// Whether the rule needs the planned value or the deadline.
    var usesDeadline: Bool {
        switch self {
        case .beforeDeadline, .onDeadlineDay: true
        default: false
        }
    }

    /// "30 min avant", "À l'heure prévue", "À 09:00 le jour prévu".
    var label: String {
        switch self {
        case .beforeStart(0): "À l’heure prévue"
        case .beforeStart(let minutes): Self.offsetText(minutes) + " avant"
        case .beforeDeadline(0): "À l’heure de l’échéance"
        case .beforeDeadline(let minutes): Self.offsetText(minutes) + " avant l’échéance"
        case .onScheduledDay(let time): "À \(time) le jour prévu"
        case .onDeadlineDay(let time): "À \(time) le jour de l’échéance"
        case .absolute(let value): "Le " + value.date.noon().formatted(.dateTime.day().month(.abbreviated)) + " à \(value.time?.description ?? "")"
        }
    }

    private static func offsetText(_ minutes: Int) -> String {
        if minutes % 1440 == 0 { return minutes == 1440 ? "1 jour" : "\(minutes / 1440) jours" }
        return DurationText.format(minutes)
    }
}

nonisolated enum ReminderTrigger: Equatable, Sendable {
    case active(Date)
    case baseMissing
}

nonisolated enum ReminderMath {
    static let windowDays = 14
    static let maxPending = 50

    /// `r:<reminderId>:<occurrenceKey|once>` (03_iOS/03_Notifications_EventKit_Widgets.md §1.3).
    static func notificationId(reminderId: String, occurrenceKey: String?) -> String {
        "r:\(reminderId.lowercased()):\(occurrenceKey ?? "once")"
    }

    /// The caller passes the effective schedule of the occurrence (its override included).
    static func trigger(_ rule: ReminderRule, schedule: TimeValue?, deadline: TimeValue?, deviceZone: TimeZone) -> ReminderTrigger {
        switch rule {
        case .absolute(let value):
            return value.instant.map(ReminderTrigger.active) ?? .baseMissing
        case .beforeStart(let minutes), .beforeDeadline(let minutes):
            let base = rule.usesDeadline ? deadline : schedule
            guard let base, base.time != nil, let instant = base.instant else { return .baseMissing }
            return .active(instant.addingTimeInterval(-TimeInterval(minutes * 60)))
        case .onScheduledDay(let time), .onDeadlineDay(let time):
            let base = rule.usesDeadline ? deadline : schedule
            guard let base, base.time == nil,
                  let resolved = TimeResolver.resolve(date: base.date, time: time, zone: deviceZone.identifier) else { return .baseMissing }
            return .active(resolved.instant)
        }
    }

    nonisolated enum State: String, Hashable, Sendable {
        case needsScheduling = "needs_scheduling"
        case scheduled
        case pendingWindow = "pending_window"
        case pendingCapacity = "pending_capacity"
        case notificationsDisabled = "notifications_disabled"
        case baseMissing = "inactive_base_missing"
        case removed
        case missed
        case displayUnknown = "display_unknown"
    }

    nonisolated struct Candidate: Sendable {
        let notificationId: String
        let trigger: ReminderTrigger
        /// False for a deleted reminder or a completed, skipped or deleted task or occurrence.
        let eligible: Bool
    }

    nonisolated struct Request: Hashable, Sendable {
        let notificationId: String
        let triggerAt: Date
    }

    nonisolated struct Plan: Sendable {
        let desired: [Request]
        let addOrReplace: [Request]
        let remove: [String]
        let states: [String: State]
    }

    /// Pure desired state (ported from reminders.ts): only requests actually pending in iOS prove scheduling;
    /// an acceptance recorded before a past trigger proves programming, never display.
    static func plan(now: Date, zone: TimeZone, authorized: Bool, candidates: [Candidate],
                     systemPending: [Request], acceptances: [String: (triggerAt: Date, acceptedAt: Date)]) -> Plan {
        let local = TimeResolver.project(now, into: zone)
        let second = Int(now.timeIntervalSince1970.rounded(.down)) % 60
        let horizonWall = WallClock.seconds(local.date.adding(days: windowDays), local.time, second: second)
        let horizon = TimeResolver.instant(wallSeconds: horizonWall, zone: zone).addingTimeInterval(now.timeIntervalSince1970 - now.timeIntervalSince1970.rounded(.down))
        let pending = Dictionary(systemPending.map { ($0.notificationId, $0.triggerAt) }, uniquingKeysWith: { first, _ in first })
        var states: [String: State] = [:]
        var eligible: [Request] = []
        for candidate in candidates {
            let id = candidate.notificationId
            guard candidate.eligible else { states[id] = .removed; continue }
            guard case .active(let trigger) = candidate.trigger else { states[id] = .baseMissing; continue }
            if trigger <= now {
                if let accepted = acceptances[id], accepted.triggerAt == trigger, accepted.acceptedAt < trigger {
                    states[id] = .displayUnknown
                } else {
                    states[id] = .missed
                }
                continue
            }
            guard authorized else { states[id] = .notificationsDisabled; continue }
            guard trigger <= horizon else { states[id] = .pendingWindow; continue }
            states[id] = .pendingCapacity
            eligible.append(Request(notificationId: id, triggerAt: trigger))
        }
        eligible.sort { ($0.triggerAt, $0.notificationId) < ($1.triggerAt, $1.notificationId) }
        let desired = Array(eligible.prefix(maxPending))
        let desiredIds = Set(desired.map(\.notificationId))
        var addOrReplace: [Request] = []
        for request in desired {
            let accepted = pending[request.notificationId].map { abs($0.timeIntervalSince(request.triggerAt)) < 0.5 } ?? false
            states[request.notificationId] = accepted ? .scheduled : .needsScheduling
            if !accepted { addOrReplace.append(request) }
        }
        let remove = pending.keys.filter { $0.hasPrefix("r:") && !desiredIds.contains($0) }.sorted()
        return Plan(desired: desired, addOrReplace: addOrReplace, remove: remove, states: states)
    }
}
