import Foundation
import PowerSync
import Testing
@testable import Planner

@MainActor
struct TaskDetailsTests {
    private let taskId = "00000000-0000-4000-8000-000000000001"
    private let tagId = "00000000-0000-4000-8000-000000000002"
    private let subtaskId = "00000000-0000-4000-8000-000000000003"

    @Test func relationIdentityMatchesSharedServerFixtureAndNamesKeepAccents() {
        #expect(TaskTagIdentity.id(taskId: taskId, tagId: tagId) == "516867fc-e615-5368-8b25-962ecda6adf5")
        #expect(TaskTagIdentity.id(taskId: taskId.uppercased(), tagId: tagId.uppercased()) == TaskTagIdentity.id(taskId: taskId, tagId: tagId))
        #expect(TagItem.normalizedName(" Straße ") == TagItem.normalizedName("STRASSE"))
        #expect(TagItem.normalizedName("CAFÉ") == TagItem.normalizedName("Cafe\u{301}"))
        #expect(TagItem.normalizedName("cafe") != TagItem.normalizedName("café"))
    }

    @Test func createKeepsDescriptionChecklistTagsAndExactCommandsInOneOfflineTransaction() async throws {
        try await withDatabase { db in
            let repo = TaskRepository(db: db)
            let tag = try await repo.createTag(name: " Maison ")
            var draft = TaskDraft()
            draft.title = "Préparer"
            draft.notes = "Description conservée"
            draft.subtasks = [TaskSubtask(id: subtaskId, title: " Première étape ", isCompleted: true, sortOrder: 4)]
            draft.tagIds = [tag]
            let id = try await repo.create(draft)
            let stored = try await repo.task(id: id)
            let task = try #require(stored)
            #expect(task.notes == draft.notes)
            #expect(task.subtasks == [TaskSubtask(id: subtaskId, title: "Première étape", isCompleted: true, sortOrder: 4)])
            let link = try await db.get(sql: "SELECT id, tag_id FROM task_tags WHERE task_id = ?", parameters: [id]) {
                (id: try $0.getString(index: 0), tag: try $0.getString(index: 1))
            }
            #expect(link.id == TaskTagIdentity.id(taskId: id, tagId: tag))
            #expect(link.tag == tag)
            let commands = try await commands(db)
            #expect(commands.map { $0["type"] } == ["tag.create", "task.create"])
            let creation = try #require(commands.last)
            let payload = try object(#require(creation["payload"]))
            #expect(payload["notes"] == .string(draft.notes))
            let expectedSubtasks = try JSONPayload.decode(JSONPayload.array(draft.subtasks.map(\.payload)).encodedText())
            #expect(payload["subtasks"] == expectedSubtasks)
            #expect(payload["tagIds"] == [.string(tag)])
            #expect(creation["precondition"] == nil) // A tag aggregate is never used as the task's revision dependency.
        }
    }

    @Test func checklistPatchPreservesConcurrentRowsAndUnchangedParentFieldsAndChainsFreshCommands() async throws {
        try await withDatabase { db in
            let repo = TaskRepository(db: db)
            let first = TaskSubtask(id: subtaskId, title: "Première", sortOrder: 0)
            try await seedTask(subtasks: [first], in: db)
            let stored = try await repo.task(id: taskId)
            let base = TaskDraft(task: try #require(stored))
            let addedElsewhere = TaskSubtask(title: "Ajout ailleurs", sortOrder: 1)
            var renamed = first
            renamed.title = "Renommée ailleurs"
            let latest = try JSONPayload.array([renamed, addedElsewhere].map(\.payload)).encodedText()
            try await db.execute(sql: "UPDATE tasks SET title = 'Parent changé ailleurs', notes = 'À préserver', subtasks = ? WHERE id = ?", parameters: [latest, taskId])
            var draft = base
            draft.subtasks[0].isCompleted = true
            try await repo.update(taskId, from: base, to: draft)
            let updatedValue = try await repo.task(id: taskId)
            let updated = try #require(updatedValue)
            #expect(updated.title == "Parent changé ailleurs")
            #expect(updated.notes == "À préserver")
            #expect(updated.subtasks.count == 2)
            #expect(updated.subtasks[0].title == "Renommée ailleurs")
            #expect(updated.subtasks[0].isCompleted)
            #expect(updated.subtasks[1] == addedElsewhere)
            var next = TaskDraft(task: updated)
            let secondBase = next
            next.subtasks.removeFirst()
            try await repo.update(taskId, from: secondBase, to: next)
            let commands = try await commands(db)
            #expect(commands.count == 2)
            #expect(commands[0]["payload"] == ["subtaskId": .string(subtaskId), "set": ["isCompleted": true]])
            let firstId = try #require(commands[0]["clientCommandId"])
            #expect(commands[1]["precondition"] == ["kind": "afterCommand", "clientCommandId": firstId])
        }
    }

    @Test func failedTagAssignmentRollsBackAllTaskChangesAndOutboxEntries() async throws {
        try await withDatabase { db in
            let repo = TaskRepository(db: db)
            try await seedTask(subtasks: [TaskSubtask(id: subtaskId, title: "Avant")], in: db)
            let stored = try await repo.task(id: taskId)
            let task = try #require(stored)
            let base = TaskDraft(task: task)
            var draft = base
            draft.title = "Ne doit pas rester"
            draft.subtasks[0].isCompleted = true
            draft.tagIds = [tagId] // Not present locally: validation must fail within the transaction.
            await #expect(throws: TaskDetailsError.unavailableTag) { try await repo.update(taskId, from: base, to: draft) }
            let after = try await repo.task(id: taskId)
            let queue = try await commands(db)
            #expect(after == task)
            #expect(queue.isEmpty)
            var creation = TaskDraft()
            creation.title = "Création refusée localement"
            creation.tagIds = [tagId]
            await #expect(throws: TaskDetailsError.unavailableTag) { try await repo.create(creation) }
            let count = try await db.get(sql: "SELECT count(*) FROM tasks", parameters: []) { try $0.getInt(index: 0) }
            #expect(count == 1)
        }
    }

    @Test func tagsCanBeDeletedRestoredAndUnassignedWithoutLosingStableRelations() async throws {
        try await withDatabase { db in
            let repo = TaskRepository(db: db)
            let tag = try await repo.createTag(name: "École")
            await #expect(throws: TaskDetailsError.duplicateTagName) { try await repo.createTag(name: " e\u{301}COLE ") }
            await #expect(throws: TaskDetailsError.invalidTagName) { try await repo.createTag(name: String(repeating: "😀", count: 26)) }
            var draft = TaskDraft()
            draft.title = "Tâche"
            draft.tagIds = [tag]
            let id = try await repo.create(draft)
            let linkId = TaskTagIdentity.id(taskId: id, tagId: tag)
            try await repo.setTagDeleted(tag, true)
            let activeLink = try await db.get(sql: "SELECT count(*) FROM task_tags WHERE id = ? AND deleted_at IS NULL", parameters: [linkId]) { try $0.getInt(index: 0) }
            #expect(activeLink == 1)
            let stored = try await repo.task(id: id)
            let base = TaskDraft(task: try #require(stored), tagIds: [tag])
            var removed = base
            removed.tagIds = []
            try await repo.update(id, from: base, to: removed)
            try await repo.setTagDeleted(tag, false)
            try await repo.update(id, from: removed, to: base)
            let links = try await db.getAll(sql: "SELECT id FROM task_tags WHERE task_id = ? AND deleted_at IS NULL", parameters: [id]) { try $0.getString(index: 0) }
            #expect(links == [linkId])
        }
    }

    @Test func seriesAndChecklistLimitAreRejectedAndReorderingUsesSnapshotRevision() async throws {
        try await withDatabase { db in
            let repo = TaskRepository(db: db)
            var draft = TaskDraft()
            draft.title = "Série incompatible"
            draft.schedule = TimeValue(date: CivilDate(year: 2026, month: 9, day: 17))
            draft.recurrence = RecurrenceRule(json: "{\"v\":1,\"mode\":\"fixed\",\"freq\":\"daily\",\"interval\":1}")
            draft.subtasks = [TaskSubtask(title: "Interdite")]
            await #expect(throws: TaskDetailsError.recurringSubtasks) { try await repo.create(draft) }
            draft.recurrence = nil
            draft.subtasks = (0..<51).map { TaskSubtask(title: "Étape \($0)", sortOrder: Double($0)) }
            await #expect(throws: TaskDetailsError.subtaskLimit) { try await repo.create(draft) }
            try await seedTask(subtasks: [TaskSubtask(id: subtaskId, title: "À déplacer")], in: db)
            let stored = try await repo.task(id: taskId)
            let base = TaskDraft(task: try #require(stored))
            var changed = base
            changed.subtasks[0].sortOrder = 2
            changed.notes = "Même enregistrement"
            try await repo.update(taskId, from: base, to: changed)
            let queue = try await commands(db)
            #expect(queue.count == 2)
            #expect(queue[0]["type"] == "task.subtask.patch")
            #expect(queue[0]["precondition"] == ["kind": "revision", "revision": 7])
            #expect(queue[1]["type"] == "task.patch")
        }
    }

    @Test func assistantSettingDefaultsToFalseAndQueuesOnlyThePairedOwner() async throws {
        try await withDatabase { db in
            let repo = TaskRepository(db: db)
            for try await values in try repo.observeAutoTags() { #expect(values == [false]); break }
            await #expect(throws: TaskDetailsError.missingOwner) { try await repo.setAutoTags(true) }
            let owner = "00000000-0000-4000-8000-000000000099"
            try await LocalMeta.setOwnerUserId(owner, in: db)
            try await repo.setAutoTags(true)
            try await repo.setAutoTags(false)
            let syncState = try await repo.assistantSettingsSyncState()
            #expect(syncState.pending)
            #expect(!syncState.rejected)
            let queue = try await commands(db)
            #expect(queue.count == 2)
            #expect(queue[0]["aggregate"] == ["type": "settings", "id": .string(owner)])
            #expect(queue[0]["payload"] == ["set": ["autoTags": true]])
            #expect(queue[1]["payload"] == ["set": ["autoTags": false]])
            for try await values in try repo.observeAutoTags() { #expect(values == [false]); break }
        }
    }

    @Test func dormantTagLinksDoNotUseQuotaAndRestoreCannotOverfillTask() async throws {
        try await withDatabase { db in
            let repo = TaskRepository(db: db)
            var draft = TaskDraft()
            draft.title = "Quota"
            var tags: [String] = []
            for index in 0..<10 { tags.append(try await repo.createTag(name: "Tag \(index)")) }
            draft.tagIds = Set(tags)
            let id = try await repo.create(draft)
            try await repo.setTagDeleted(tags[0], true)
            let extra = try await repo.createTag(name: "Nouveau tag actif")
            let stored = try await repo.task(id: id)
            let base = TaskDraft(task: try #require(stored), tagIds: Set(tags))
            var changed = base
            changed.tagIds.insert(extra) // 11 retained links, but only 10 active tags.
            try await repo.update(id, from: base, to: changed)
            let count = try await db.get(sql: "SELECT count(*) FROM task_tags WHERE task_id = ? AND deleted_at IS NULL", parameters: [id]) { try $0.getInt(index: 0) }
            #expect(count == 11)
            await #expect(throws: TaskDetailsError.taskTagLimit) { try await repo.setTagDeleted(tags[0], false) }
            try await repo.setTagDeleted(extra, true)
            try await repo.setTagDeleted(tags[0], false)
            let preserved = try await db.get(sql: "SELECT count(*) FROM task_tags WHERE task_id = ? AND deleted_at IS NULL", parameters: [id]) { try $0.getInt(index: 0) }
            #expect(preserved == 11)
        }
    }

    @Test func replacingFullChecklistKeepsAll102CommandsInOneLocalTransaction() async throws {
        try await withDatabase { db in
            let repo = TaskRepository(db: db)
            let original = (0..<50).map { TaskSubtask(title: "Ancienne \($0)", sortOrder: Double($0)) }
            try await seedTask(subtasks: original, in: db)
            try await db.execute(sql: "INSERT INTO tags (id, name, revision) VALUES (?, 'Tag connu', 1)", parameters: [tagId])
            let stored = try await repo.task(id: taskId)
            let base = TaskDraft(task: try #require(stored))
            var draft = base
            draft.subtasks = (0..<50).map { TaskSubtask(title: "Nouvelle \($0)", sortOrder: Double($0)) }
            draft.tagIds = [tagId]
            draft.notes = "Description changée"
            try await repo.update(taskId, from: base, to: draft)
            let queue = try await commands(db)
            #expect(queue.count == 102)
            #expect(queue.filter { $0["type"] == "task.subtask.remove" }.count == 50)
            #expect(queue.filter { $0["type"] == "task.subtask.add" }.count == 50)
            let transactions = try await db.getAll(sql: "SELECT DISTINCT tx_id FROM ps_crud WHERE json_extract(data, '$.type') = 'outbox'", parameters: []) { try $0.getInt(index: 0) }
            #expect(transactions.count == 1)
            let updated = try await repo.task(id: taskId)
            #expect(updated?.subtasks.count == 50)
        }
    }

    @Test func newFieldLimitsMatchUTF16AndRejectedCreationKeepsDetailsWithFreshSubtaskIds() throws {
        #expect(!TaskSubtask.areValid([TaskSubtask(title: String(repeating: "😀", count: 251))]))
        let commandId = UUID().uuidString.lowercased()
        let command: JSONPayload = [
            "clientCommandId": .string(commandId), "type": "task.create", "payloadVersion": 1,
            "aggregate": ["type": "task", "id": .string(taskId)], "clientRecordedAt": "2026-09-17T10:00:00Z",
            "payload": ["title": "À corriger", "subtasks": [["id": .string(subtaskId), "title": "À garder", "isCompleted": true]], "tagIds": [.string(tagId)]],
        ]
        let rejection = SyncQueueRepository.Rejection(id: commandId, commandType: "task.create", aggregateId: taskId, code: "TAG_DELETED", rejectedAt: nil, commandJSON: try command.encodedText())
        let intent = try #require(SyncRejectionIntent(rejection: rejection))
        let draft = try intent.prefilledDraft()
        #expect(draft.subtasks.count == 1)
        #expect(draft.subtasks[0].id != subtaskId)
        #expect(draft.subtasks[0].title == "À garder")
        #expect(draft.subtasks[0].isCompleted)
        #expect(draft.tagIds == [tagId])
    }

    private func seedTask(subtasks: [TaskSubtask], in db: any PowerSyncDatabaseProtocol) async throws {
        let json = try JSONPayload.array(subtasks.map(\.payload)).encodedText()
        try await db.execute(sql: "INSERT INTO tasks (id, title, status, priority, revision, subtasks) VALUES (?, 'Originale', 'active', 'none', 7, ?)", parameters: [taskId, json])
    }

    private func commands(_ db: any PowerSyncDatabaseProtocol) async throws -> [[String: JSONPayload]] {
        let archive = try await LocalExportRepository(db: db).archive(context: LocalExportContext(hasSynced: true, lastSyncedAt: nil, connection: "offline"))
        return try archive.pendingCommands.map { try object(#require($0.command)) }
    }

    private func object(_ value: JSONPayload) throws -> [String: JSONPayload] {
        guard case .object(let object) = value else { throw FixtureError.invalidJSON }
        return object
    }

    private func withDatabase(_ work: @MainActor (any PowerSyncDatabaseProtocol) async throws -> Void) async throws {
        let db = LocalDatabase.open(fileName: "task-details-" + UUID().uuidString + ".sqlite")
        do { try await work(db); try await db.disconnectAndClear() }
        catch { try? await db.disconnectAndClear(); throw error }
    }

    private enum FixtureError: Error { case invalidJSON }
}
