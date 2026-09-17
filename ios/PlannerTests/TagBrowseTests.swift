import Foundation
import PowerSync
import Testing
@testable import Planner

@MainActor
struct TagBrowseTests {
    @Test func catalogueCountsActiveTasksButLabelsRemainOnCompletedAndTrashedTasks() async throws {
        try await withDatabase { db in
            let repo = TaskRepository(db: db)
            let home = try await repo.createTag(name: "Maison")
            let empty = try await repo.createTag(name: "Sans tâche")
            let retired = try await repo.createTag(name: "Ancien")
            let active = try await create("Active", tags: [home, retired], using: repo)
            let completed = try await create("Terminée", tags: [home], using: repo)
            let trashed = try await create("Corbeille", tags: [home], using: repo)
            let unassigned = try await create("Lien retiré", tags: [home], using: repo)
            try await repo.setCompleted(completed, true)
            try await repo.setDeleted(trashed, true)
            try await repo.setTagDeleted(retired, true)
            try await db.execute(sql: "UPDATE task_tags SET deleted_at = ? WHERE task_id = ?", parameters: [Timestamp.format(Date()), unassigned])

            // A malformed duplicate assignment must not inflate counts or repeat a task/label.
            try await db.execute(sql: "INSERT INTO task_tags (id, task_id, tag_id) VALUES (?, ?, ?)",
                                 parameters: [UUID().uuidString.lowercased(), active, home])
            let queueBefore = try await queue(db)
            let snapshot = try await repo.tagDirectorySnapshot()
            let filtered = try await repo.tasks(tagId: home)
            let retiredTasks = try await repo.tasks(tagId: retired)
            let queueAfter = try await queue(db)

            #expect(snapshot.catalogue.map(\.id) == [home, empty])
            #expect(snapshot.catalogue.map(\.activeTaskCount) == [1, 0])
            #expect(snapshot.taskTags[active]?.map(\.id) == [home])
            #expect(snapshot.taskTags[completed]?.map(\.id) == [home])
            #expect(snapshot.taskTags[trashed]?.map(\.id) == [home])
            #expect(snapshot.taskTags[unassigned] == nil)
            #expect(Set(filtered.map(\.id)) == [active, completed])
            #expect(filtered.count == 2)
            #expect(retiredTasks.isEmpty)
            #expect(queueBefore == queueAfter)
        }
    }

    @Test func tagFilterIncludesEachSeriesOnceAndKeepsTheStableTaskOrder() async throws {
        try await withDatabase { db in
            let repo = TaskRepository(db: db)
            let tag = try await repo.createTag(name: "Études")
            let other = try await repo.createTag(name: "Autre")
            let later = try await create("Plus tard", tags: [tag], using: repo)
            let earlier = try await create("Plus tôt", tags: [tag], using: repo)
            let allDay = try await create("Sans heure", tags: [tag], using: repo)
            let undated = try await create("Sans date", tags: [tag], using: repo)
            let excluded = try await create("Autre tag", tags: [other], using: repo)
            let recurrence: JSONPayload = ["v": 1, "mode": "fixed", "freq": "daily", "interval": 1]
            try await db.execute(sql: "UPDATE tasks SET scheduled_date = '2026-09-20', scheduled_time = '18:00', scheduled_time_zone = 'Europe/Zurich' WHERE id = ?", parameters: [later])
            try await db.execute(sql: "UPDATE tasks SET scheduled_date = '2026-09-20', scheduled_time = '08:00', scheduled_time_zone = 'Europe/Zurich', recurrence = ? WHERE id = ?", parameters: [try recurrence.encodedText(), earlier])
            try await db.execute(sql: "UPDATE tasks SET scheduled_date = '2026-09-20' WHERE id = ?", parameters: [allDay])
            // Materialized occurrences do not multiply the series in a tag's task list or count.
            for day in ["2026-09-20", "2026-09-21"] {
                try await db.execute(sql: "INSERT INTO task_occurrences (id, task_id, occurrence_key, status) VALUES (?, ?, ?, 'open')", parameters: [UUID().uuidString.lowercased(), earlier, day])
            }
            let tasks = try await repo.tasks(tagId: tag.uppercased())
            let snapshot = try await repo.tagDirectorySnapshot()
            #expect(tasks.map(\.id) == [earlier, later, allDay, undated])
            #expect(tasks.first?.isRecurring == true)
            #expect(!tasks.contains { $0.id == excluded })
            #expect(snapshot.catalogue.first { $0.id == tag }?.activeTaskCount == 4)
        }
    }

    @Test(.timeLimit(.minutes(3))) func observationsReflectRenameCompletionUnassignmentAndTagDeletion() async throws {
        try await withDatabase { db in
            let repo = TaskRepository(db: db)
            let tag = try await repo.createTag(name: "Avant")
            let taskId = try await create("À suivre", tags: [tag], using: repo)
            var directory = try repo.observeTagDirectory().makeAsyncIterator()
            var filtered = try repo.observeTasks(tagId: tag).makeAsyncIterator()
            let firstRows = try await directory.next()
            let initialRows = try #require(firstRows)
            let initial = TagDirectorySnapshot(rows: initialRows)
            let initialTasks = try await filtered.next()
            #expect(initial.catalogue.first?.tag.name == "Avant")
            #expect(initial.catalogue.first?.activeTaskCount == 1)
            #expect(initialTasks?.map(\.id) == [taskId])

            try await repo.renameTag(tag, name: "Après")
            var renamed = false
            while let rows = try await directory.next() {
                let snapshot = TagDirectorySnapshot(rows: rows)
                if snapshot.catalogue.first?.tag.name == "Après" {
                    #expect(snapshot.taskTags[taskId]?.first?.name == "Après")
                    renamed = true
                    break
                }
            }
            #expect(renamed)
            try await repo.setCompleted(taskId, true)
            var countUpdated = false
            while let rows = try await directory.next() {
                let snapshot = TagDirectorySnapshot(rows: rows)
                if snapshot.catalogue.first?.activeTaskCount == 0 {
                    #expect(snapshot.taskTags[taskId]?.map(\.id) == [tag])
                    countUpdated = true
                    break
                }
            }
            #expect(countUpdated)
            var completionUpdated = false
            while let rows = try await filtered.next() {
                if rows.first?.isCompleted == true { completionUpdated = true; break }
            }
            #expect(completionUpdated)
            try await db.execute(sql: "UPDATE task_tags SET deleted_at = ? WHERE task_id = ?", parameters: [Timestamp.format(Date()), taskId])
            var unassigned = false
            while let rows = try await directory.next() {
                let snapshot = TagDirectorySnapshot(rows: rows)
                if snapshot.taskTags[taskId] == nil {
                    #expect(snapshot.catalogue.count == 1) // An unused tag is still browsable.
                    unassigned = true
                    break
                }
            }
            #expect(unassigned)
            var removedFromFilter = false
            while let rows = try await filtered.next() {
                if rows.isEmpty { removedFromFilter = true; break }
            }
            #expect(removedFromFilter)
            try await repo.setTagDeleted(tag, true)
            var deleted = false
            while let rows = try await directory.next() {
                if rows.isEmpty { deleted = true; break }
            }
            #expect(deleted)
            let finalSnapshot = try await repo.tagDirectorySnapshot()
            #expect(finalSnapshot.catalogue.isEmpty)
        }
    }

    private func create(_ title: String, tags: Set<String>, using repo: TaskRepository) async throws -> String {
        var draft = TaskDraft()
        draft.title = title
        draft.tagIds = tags
        return try await repo.create(draft)
    }

    private func queue(_ db: any PowerSyncDatabaseProtocol) async throws -> [String] {
        try await db.getAll(sql: "SELECT data FROM ps_crud ORDER BY id", parameters: []) { try $0.getString(index: 0) }
    }

    private func withDatabase(_ work: @MainActor (any PowerSyncDatabaseProtocol) async throws -> Void) async throws {
        let db = LocalDatabase.open(fileName: "tag-browse-" + UUID().uuidString + ".sqlite")
        do { try await work(db); try await db.disconnectAndClear() }
        catch { try? await db.disconnectAndClear(); throw error }
    }
}
