import Foundation
import PowerSync
import Testing
@testable import Planner

@MainActor
struct TasksHomeTests {
    @Test func allActiveIncludesEveryListAndSeriesButExcludesCompletedAndDeletedTasks() async throws {
        try await withDatabase { db in
            try await db.execute(sql: """
                INSERT INTO tasks (id, title, status, project_id, recurrence, deleted_at, created_at) VALUES
                ('inbox', 'Sans liste', 'active', NULL, NULL, NULL, '2026-09-17T12:00:00Z'),
                ('list', 'Avec liste', 'active', 'project', NULL, NULL, '2026-09-17T11:00:00Z'),
                ('series', 'Série active', 'active', 'project', '{"v":1,"mode":"fixed","freq":"daily","interval":1}', NULL, '2026-09-17T10:00:00Z'),
                ('completed', 'Terminée', 'completed', NULL, NULL, NULL, '2026-09-17T13:00:00Z'),
                ('ended', 'Série arrêtée', 'completed', NULL, '{"v":1,"mode":"fixed","freq":"daily","interval":1}', NULL, '2026-09-17T14:00:00Z'),
                ('deleted', 'Corbeille', 'active', NULL, NULL, '2026-09-17T15:00:00Z', '2026-09-17T15:00:00Z')
                """, parameters: [])
            let tasks = try await firstTasks(.allActive, in: db)
            #expect(tasks.map(\.id) == ["inbox", "list", "series"])
            #expect(tasks.filter(\.isRecurring).count == 1)
            let inbox = try await firstTasks(.inbox, in: db)
            #expect(inbox.map(\.id) == ["inbox"])
            let completed = try await firstTasks(.completed, in: db)
            #expect(Set(completed.map(\.id)) == ["completed", "ended"])
        }
    }

    @Test func allActiveUsesPlannedDateTimeThenCreationAndIdentifierForStableOrder() async throws {
        try await withDatabase { db in
            try await db.execute(sql: """
                INSERT INTO tasks (id, title, status, scheduled_date, scheduled_time, created_at) VALUES
                ('unscheduled-new', 'Sans date récent', 'active', NULL, NULL, '2026-09-17T12:00:00Z'),
                ('unscheduled-old', 'Sans date ancien', 'active', NULL, NULL, '2026-09-16T12:00:00Z'),
                ('later', 'Planifié plus tard', 'active', '2026-09-19', '08:00:00', '2026-09-17T12:00:00Z'),
                ('floating', 'Date sans heure', 'active', '2026-09-18', NULL, '2026-09-17T15:00:00Z'),
                ('time-new', 'Création récente', 'active', '2026-09-18', '09:00:00', '2026-09-17T13:00:00Z'),
                ('time-z', 'Même création Z', 'active', '2026-09-18', '09:00:00', '2026-09-17T12:00:00Z'),
                ('time-a', 'Même création A', 'active', '2026-09-18', '09:00:00', '2026-09-17T12:00:00Z'),
                ('earlier-hour', 'Heure précédente', 'active', '2026-09-18', '08:00:00', '2026-09-16T12:00:00Z'),
                ('earlier-day', 'Jour précédent', 'active', '2026-09-17', NULL, '2026-09-16T12:00:00Z')
                """, parameters: [])
            let rows = try await firstTasks(.allActive, in: db)
            #expect(rows.map(\.id) == [
                "earlier-day", "earlier-hour", "time-new", "time-a", "time-z", "floating", "later", "unscheduled-new", "unscheduled-old",
            ])
        }
    }

    private func firstTasks(_ filter: TaskFilter, in db: any PowerSyncDatabaseProtocol) async throws -> [TaskItem] {
        for try await rows in try TaskRepository(db: db).observeTasks(filter) { return rows }
        throw FixtureError.noSnapshot
    }

    private func withDatabase(_ work: @MainActor (any PowerSyncDatabaseProtocol) async throws -> Void) async throws {
        let db = LocalDatabase.open(fileName: "tasks-home-" + UUID().uuidString + ".sqlite")
        do {
            try await work(db)
            try await db.disconnectAndClear()
        } catch {
            try? await db.disconnectAndClear()
            throw error
        }
    }

    private enum FixtureError: Error { case noSnapshot }
}
