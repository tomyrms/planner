import Foundation
import PowerSync
import Testing
@testable import Planner

@MainActor
struct ProjectManagementTests {
    @Test func renameRefreshesSearchOfflineAndDeleteInboxDetachesEvenTrashedTasks() async throws {
        try await withDatabase { db in
            let repository = TaskRepository(db: db)
            let id = try await repository.createProject(name: " Avant ")
            let project = ProjectItem(id: id, name: "Avant", activeTaskCount: 1)
            var draft = TaskDraft()
            draft.title = "Titre"
            draft.notes = "Notes"
            draft.projectId = id
            let taskId = try await repository.create(draft)
            try await repository.setDeleted(taskId, true)
            try await repository.renameProject(project, name: " Été ")
            let search = try await db.get(sql: "SELECT search_text FROM tasks WHERE id = ?", parameters: [taskId]) { try $0.getString(index: 0) }
            #expect(search == SearchText.normalize(["Titre", "Notes", "Été"]))
            try await repository.deleteProject(project, policy: .inbox)
            let task = try await repository.task(id: taskId)
            #expect(task?.projectId == nil)
            #expect(task?.isDeleted == true)
            try await repository.restoreProject(project)
            let restored = try await repository.task(id: taskId)
            #expect(restored?.projectId == nil)
            #expect(restored?.isDeleted == true)
            try await repository.setDeleted(taskId, false)
            let queue = try await commands(db)
            #expect(queue.last?["precondition"] == ["kind": "afterCommand", "clientCommandId": queue[4]["clientCommandId"]!])
            #expect(queue[4]["payload"] == ["taskPolicy": "move_tasks_to_inbox"])
        }
    }

    @Test func restoreOnlyRevivesTasksTrashedByThisListAndPendingEditsFollowItsReceipt() async throws {
        try await withDatabase { db in
            let repository = TaskRepository(db: db)
            let id = try await repository.createProject(name: "Liste")
            let project = ProjectItem(id: id, name: "Liste", activeTaskCount: 1)
            var draft = TaskDraft()
            draft.title = "Avant"
            draft.projectId = id
            let alreadyTrashed = try await repository.create(draft)
            try await repository.setDeleted(alreadyTrashed, true)
            draft.title = "Avec la liste"
            let member = try await repository.create(draft)
            try await repository.deleteProject(project, policy: .trash)
            await #expect(throws: ProjectMutationError.self) { try await repository.setDeleted(member, false) }
            try await repository.restoreProject(project)
            let existing = try await repository.task(id: alreadyTrashed)
            let restored = try await repository.task(id: member)
            #expect(existing?.isDeleted == true)
            #expect(restored?.isDeleted == false)
            try await repository.setCompleted(member, true)
            let queue = try await commands(db)
            let restore = try #require(queue.first { $0["type"] == "project.restore" })
            #expect(queue.last?["precondition"] == ["kind": "afterCommand", "clientCommandId": restore["clientCommandId"]!])
            let deletion = try await db.get(sql: "SELECT deleted_by_command_id FROM tasks WHERE id = ?", parameters: [alreadyTrashed]) { try $0.getString(index: 0) }
            #expect(JSONPayload.string(deletion) == queue[2]["clientCommandId"])
        }
    }

    @Test func invalidNamesAndMissingProjectLeaveProjectionAndQueueUntouched() async throws {
        try await withDatabase { db in
            let repository = TaskRepository(db: db)
            await #expect(throws: ProjectMutationError.self) { try await repository.createProject(name: " \n ") }
            await #expect(throws: ProjectMutationError.self) { try await repository.createProject(name: String(repeating: "😀", count: 101)) }
            let missing = ProjectItem(id: UUID().uuidString.lowercased(), name: "Absente", activeTaskCount: 0, revision: 3)
            await #expect(throws: ProjectMutationError.self) { try await repository.deleteProject(missing, policy: .trash) }
            let queue = try await commands(db)
            #expect(queue.isEmpty)
            let count = try await db.get(sql: "SELECT count(*) FROM projects", parameters: []) { try $0.getInt(index: 0) }
            #expect(count == 0)
        }
    }

    @Test func checklistMovesPreserveIdentityAndCheckedStateInBothDirections() {
        let a = TaskSubtask(title: "A", isCompleted: true, sortOrder: 10)
        let b = TaskSubtask(title: "B", sortOrder: 20)
        let c = TaskSubtask(title: "C", sortOrder: 30)
        let forward = TaskSubtask.moving([a, b, c], from: IndexSet(integer: 0), to: 3)
        #expect(forward.map(\.id) == [b.id, c.id, a.id])
        #expect(forward[2].isCompleted)
        #expect(forward.map(\.sortOrder) == [0, 1, 2])
        let back = TaskSubtask.moving(forward, from: IndexSet(integer: 2), to: 0)
        #expect(back.map(\.id) == [a.id, b.id, c.id])
        #expect(TaskSubtask.moving(back, from: IndexSet(integer: 0), to: -1) == back)
        let multi = TaskSubtask.moving([a, b, c], from: IndexSet([0, 1]), to: 3)
        #expect(multi.map(\.id) == [c.id, a.id, b.id])
    }

    @Test func sameUUIDInAnotherAggregateDoesNotCreateATaskRevisionDependency() async throws {
        try await withDatabase { db in
            let repository = TaskRepository(db: db)
            let id = try await repository.createProject(name: "Liste")
            try await db.execute(sql: "INSERT INTO tasks (id, title, status, priority, revision) VALUES (?, 'Tâche indépendante', 'active', 'none', 1)", parameters: [id])
            try await repository.setCompleted(id, true)
            let queue = try await commands(db)
            #expect(queue.count == 2)
            #expect(queue[1]["precondition"] == nil)
        }
    }

    @Test func staleTaskEditorCannotCreateIntoAListDeletedWhileItWasOpen() async throws {
        try await withDatabase { db in
            let repository = TaskRepository(db: db)
            let id = try await repository.createProject(name: "Liste")
            let project = ProjectItem(id: id, name: "Liste", activeTaskCount: 0)
            var draft = TaskDraft()
            draft.title = "Brouillon ouvert"
            draft.projectId = id
            try await repository.deleteProject(project, policy: .inbox)
            await #expect(throws: ProjectMutationError.self) { try await repository.create(draft) }
            let count = try await db.get(sql: "SELECT count(*) FROM tasks", parameters: []) { try $0.getInt(index: 0) }
            let queue = try await commands(db)
            #expect(count == 0)
            #expect(queue.count == 2)
        }
    }

    private func commands(_ db: any PowerSyncDatabaseProtocol) async throws -> [[String: JSONPayload]] {
        let archive = try await LocalExportRepository(db: db).archive(context: LocalExportContext(hasSynced: true, connection: "offline"))
        return try archive.pendingCommands.map {
            guard let payload = $0.command, case .object(let command) = payload else { throw TestError.invalidCommand }
            return command
        }
    }

    private func withDatabase(_ work: @MainActor (any PowerSyncDatabaseProtocol) async throws -> Void) async throws {
        let db = LocalDatabase.open(fileName: "project-management-" + UUID().uuidString + ".sqlite")
        do { try await work(db); try await db.disconnectAndClear() }
        catch { try? await db.disconnectAndClear(); throw error }
    }

    private enum TestError: Error { case invalidCommand }
}
