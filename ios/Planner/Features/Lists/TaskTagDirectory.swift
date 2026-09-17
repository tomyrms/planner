import Foundation
import Observation

/// One owned SQLite watch per app session, shared by all task rows instead of one watch per row.
@Observable
final class TaskTagDirectory {
    private(set) var snapshot = TagDirectorySnapshot()
    private(set) var loaded = false
    private(set) var failed = false
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var observationId: UUID?

    func tags(for taskId: String) -> [TagItem] { snapshot.taskTags[taskId] ?? [] }
    func tag(id: String) -> TagItem? { snapshot.catalogue.first { $0.id == id }?.tag }

    func start(_ repository: TaskRepository) {
        stop()
        let id = UUID()
        observationId = id
        loaded = false
        failed = false
        listener = Task { [weak self] in
            do {
                for try await rows in try repository.observeTagDirectory() {
                    guard !Task.isCancelled, let self, self.observationId == id else { return }
                    self.snapshot = TagDirectorySnapshot(rows: rows)
                    self.loaded = true
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self, self.observationId == id else { return }
                self.failed = true
            }
        }
    }

    func stop() {
        observationId = nil
        listener?.cancel()
        listener = nil
    }
}
