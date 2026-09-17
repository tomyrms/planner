import Foundation
import Observation

/// Dated tasks, materialized occurrences and reminders, observed once for Today, Upcoming, Calendar and editors.
@Observable
final class AgendaStore {
    private(set) var tasks: [TaskItem] = []
    private(set) var occurrences: [String: [OccurrenceRow]] = [:]
    private(set) var reminders: [String: [ReminderRow]] = [:]
    private(set) var loaded = false
    private(set) var readFailed = false
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var observationId: UUID?

    func start(_ repository: TaskRepository) {
        stop()
        let id = UUID()
        observationId = id
        loaded = false
        readFailed = false
        listeners.append(Task { [weak self] in
            do {
                for try await rows in try repository.observeTasks(.dated) {
                    guard !Task.isCancelled, self?.observationId == id else { return }
                    self?.tasks = rows
                    self?.loaded = true
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), self?.observationId == id else { return }
                self?.readFailed = true
            }
        })
        listeners.append(Task { [weak self] in
            do {
                for try await rows in try repository.observeOccurrences() {
                    guard !Task.isCancelled, self?.observationId == id else { return }
                    self?.occurrences = Dictionary(grouping: rows, by: \.taskId)
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), self?.observationId == id else { return }
                self?.readFailed = true
            }
        })
        listeners.append(Task { [weak self] in
            do {
                for try await rows in try repository.observeReminders() {
                    guard !Task.isCancelled, self?.observationId == id else { return }
                    self?.reminders = Dictionary(grouping: rows, by: \.taskId)
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), self?.observationId == id else { return }
                self?.readFailed = true
            }
        })
    }

    func stop() {
        observationId = nil
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
