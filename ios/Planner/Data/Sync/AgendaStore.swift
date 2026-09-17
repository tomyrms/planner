import Foundation
import Observation

/// Dated tasks, materialized occurrences and reminders, observed once for Today, Upcoming, Calendar and editors.
@Observable
final class AgendaStore {
    private(set) var tasks: [TaskItem] = []
    private(set) var occurrences: [String: [OccurrenceRow]] = [:]
    private(set) var reminders: [String: [ReminderRow]] = [:]
    private(set) var loaded = false
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []

    func start(_ repository: TaskRepository) {
        stop()
        listeners.append(Task { [weak self] in
            do {
                for try await rows in try repository.observeTasks(.dated) {
                    self?.tasks = rows
                    self?.loaded = true
                }
            } catch {}
        })
        listeners.append(Task { [weak self] in
            do {
                for try await rows in try repository.observeOccurrences() {
                    self?.occurrences = Dictionary(grouping: rows, by: \.taskId)
                }
            } catch {}
        })
        listeners.append(Task { [weak self] in
            do {
                for try await rows in try repository.observeReminders() {
                    self?.reminders = Dictionary(grouping: rows, by: \.taskId)
                }
            } catch {}
        })
    }

    func stop() {
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
    }

    /// The reminder the V1 editor shows: the one without an occurrence key.
    func reminder(of taskId: String) -> ReminderRow? {
        reminders[taskId]?.first { $0.occurrenceKey == nil }
    }

    func rows(of taskId: String) -> [OccurrenceRow] {
        occurrences[taskId] ?? []
    }

    func today(_ date: CivilDate) -> TodayAgenda {
        TodayAgenda(tasks: tasks, occurrences: occurrences, today: date)
    }

    func upcoming(_ today: CivilDate) -> UpcomingAgenda {
        UpcomingAgenda(tasks: tasks, occurrences: occurrences, today: today)
    }

    func days(from: CivilDate, through: CivilDate) -> [CivilDate: DayAgenda] {
        DayAgenda.days(tasks: tasks, occurrences: occurrences, from: from, through: through)
    }
}
