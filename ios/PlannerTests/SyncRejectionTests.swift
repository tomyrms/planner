import Foundation
import PowerSync
import Testing
@testable import Planner

@MainActor
struct SyncRejectionTests {
    private let taskId = "11111111-1111-4111-8111-111111111111"
    private let commandId = "22222222-2222-4222-8222-222222222222"
    private let oldDependency = "33333333-3333-4333-8333-333333333333"

    @Test func patchPrefillKeepsAbsentFieldsAndClearsExplicitNulls() throws {
        var current = TaskDraft()
        current.title = "Titre actuel"
        current.notes = "Note actuelle"
        current.priority = .high
        current.durationMinutes = 45
        current.schedule = TimeValue(date: CivilDate(year: 2026, month: 10, day: 25))
        let rejection = try rejection(type: "task.patch", payload: ["set": ["title": "Titre refusé", "notes": .null]])
        let intent = try #require(SyncRejectionIntent(rejection: rejection))
        let draft = try intent.prefilledDraft(current: current)
        #expect(draft.title == "Titre refusé")
        #expect(draft.notes.isEmpty)
        #expect(draft.priority == current.priority)
        #expect(draft.schedule == current.schedule)
        #expect(draft.durationMinutes == 45)
        #expect(intent.patchFields == ["title", "notes"])
        #expect(intent.dependsOn == oldDependency)
        #expect(rejection.commandJSON != nil)
    }

    @Test func createPrefillPreservesCivilDatesZoneRecurrenceAndReminderWithoutReusingItsId() throws {
        let schedule: JSONPayload = ["date": "2026-10-25", "time": "02:30", "timeZone": "Europe/Zurich"]
        let recurrence: JSONPayload = ["v": 1, "mode": "fixed", "freq": "daily", "interval": 1]
        let payload: JSONPayload = [
            "title": "Série refusée", "schedule": schedule, "recurrence": recurrence, "durationMinutes": 37,
            "reminders": [["id": "44444444-4444-4444-8444-444444444444", "rule": ["kind": "before_start", "offsetMinutes": 15]]],
        ]
        let record = try rejection(type: "task.create", payload: payload)
        let intent = try #require(SyncRejectionIntent(rejection: record))
        let draft = try intent.prefilledDraft()
        #expect(draft.schedule?.payload == schedule)
        #expect(draft.recurrence?.payload == recurrence)
        #expect(draft.durationMinutes == 37)
        #expect(draft.reminder == .beforeStart(minutes: 15))
        #expect(draft.reminderId == nil)
    }

    @Test func legacyUnknownAndUnrepresentableRequestsStayReadableWithoutLossyPrefill() throws {
        let legacy = SyncQueueRepository.Rejection(id: commandId, commandType: "task.patch", aggregateId: taskId, code: "REVISION_MISMATCH", rejectedAt: nil)
        #expect(SyncRejectionIntent(rejection: legacy) == nil)
        let future = try rejection(type: "task.patch", payload: ["set": ["title": "Futur"]], version: 2)
        let futureIntent = try #require(SyncRejectionIntent(rejection: future))
        #expect(!futureIntent.supportsEditor)
        #expect(!futureIntent.fields.isEmpty)
        let malformed = try rejection(type: "task.patch", payload: ["set": ["schedule": ["date": "2026-02-31"]]])
        let malformedIntent = try #require(SyncRejectionIntent(rejection: malformed))
        #expect(throws: SyncRejectionIntent.PreparationError.invalidField("Planification")) {
            _ = try malformedIntent.prefilledDraft(current: TaskDraft())
        }
        let unsupported = try rejection(type: "task.patch", payload: ["set": ["unknownField": "Conserver"]])
        let unsupportedIntent = try #require(SyncRejectionIntent(rejection: unsupported))
        #expect(throws: SyncRejectionIntent.PreparationError.invalidField("unknownField")) {
            _ = try unsupportedIntent.prefilledDraft(current: TaskDraft())
        }
        let extremeRule = try rejection(type: "task.create", payload: [
            "title": "Règle refusée", "schedule": ["date": "2026-10-25"],
            "recurrence": ["v": 1, "mode": "fixed", "freq": "daily", "interval": 1, "count": .double(1e100)],
        ])
        let extremeIntent = try #require(SyncRejectionIntent(rejection: extremeRule))
        #expect(throws: SyncRejectionIntent.PreparationError.invalidField("Répétition")) {
            _ = try extremeIntent.prefilledDraft()
        }
    }

    @Test func correctingCreateGeneratesNewTaskCommandAndReminderAndKeepsTheRejection() async throws {
        try await withDatabase { db in
            let record = try rejection(type: "task.create", payload: [
                "title": "Titre refusé", "schedule": ["date": "2026-10-25"],
                "reminders": [["id": "44444444-4444-4444-8444-444444444444", "rule": ["kind": "on_scheduled_day_at", "localTime": "09:00"]]],
            ])
            try await seed(record, in: db)
            let intent = try #require(SyncRejectionIntent(rejection: record))
            let draft = try intent.prefilledDraft()
            let id = try await TaskRepository(db: db).create(draft)
            let commands = try await commands(in: db)
            let command = try #require(commands.first)
            #expect(id != taskId)
            #expect(command["clientCommandId"] != .string(commandId))
            #expect(command["precondition"] == nil)
            let payload = try object(#require(command["payload"]))
            let reminders = try array(#require(payload["reminders"]))
            let reminder = try object(#require(reminders.first))
            #expect(reminder["id"] != "44444444-4444-4444-8444-444444444444")
            let saved = try await SyncQueueRepository(db: db).rejection(id: record.id)
            #expect(saved?.commandJSON == record.commandJSON)
        }
    }

    @Test func unchangedOptimisticFieldsAreActuallyReappliedWithFreshCausality() async throws {
        try await withDatabase { db in
            try await db.execute(sql: "INSERT INTO tasks (id, title, notes, priority, status, revision) VALUES (?, 'Refusé', 'À conserver', 'high', 'active', 8)", parameters: [taskId])
            let record = try rejection(type: "task.patch", payload: ["set": ["title": "Refusé"]])
            try await seed(record, in: db)
            let tasks = TaskRepository(db: db)
            let stored = try await tasks.task(id: taskId)
            let task = try #require(stored)
            let base = TaskDraft(task: task)
            let intent = try #require(SyncRejectionIntent(rejection: record))
            let proposed = try intent.prefilledDraft(current: base)
            #expect(proposed == base) // The refused optimistic value is still visible locally.
            try await tasks.update(taskId, from: base, to: proposed, reapplying: intent.patchFields)
            var commands = try await commands(in: db)
            let first = try #require(commands.first)
            #expect(first["clientCommandId"] != .string(commandId))
            #expect(first["precondition"] == nil) // The old afterCommand is never reused.
            #expect(first["payload"] == ["set": ["title": "Refusé"]])
            try await tasks.update(taskId, from: base, to: proposed, reapplying: intent.patchFields)
            commands = try await self.commands(in: db)
            let second = try #require(commands.last)
            let firstId = try #require(first["clientCommandId"])
            #expect(second["precondition"] == ["kind": "afterCommand", "clientCommandId": firstId])
            let saved = try await SyncQueueRepository(db: db).rejection(id: record.id)
            #expect(saved?.commandJSON == record.commandJSON)
        }
    }

    @Test func seriesCorrectionUsesTheCurrentRevisionAndDoesNotReuseTheRefusedPrecondition() async throws {
        try await withDatabase { db in
            try await db.execute(sql: """
                INSERT INTO tasks (id, title, priority, status, revision, scheduled_date, recurrence)
                VALUES (?, 'Série', 'none', 'active', 12, '2026-10-25', '{"v":1,"mode":"fixed","freq":"daily","interval":1}')
                """, parameters: [taskId])
            let tasks = TaskRepository(db: db)
            let stored = try await tasks.task(id: taskId)
            let task = try #require(stored)
            let draft = TaskDraft(task: task)
            try await tasks.updateSeries(task, from: draft, to: draft, reapplying: ["title"])
            let queued = try await commands(in: db)
            let command = try #require(queued.first)
            #expect(command["type"] == "series.update")
            #expect(command["precondition"] == ["kind": "revision", "revision": 12])
            #expect(command["payload"] == ["set": ["title": "Série"]])
        }
    }

    private func rejection(type: String, payload: JSONPayload, version: Int = 1) throws -> SyncQueueRepository.Rejection {
        let command: JSONPayload = [
            "clientCommandId": .string(commandId), "type": .string(type), "payloadVersion": .int(version),
            "aggregate": ["type": "task", "id": .string(taskId)], "clientRecordedAt": "2026-09-17T10:00:00.000Z",
            "precondition": ["kind": "afterCommand", "clientCommandId": .string(oldDependency)], "payload": payload,
        ]
        return SyncQueueRepository.Rejection(id: commandId, commandType: type, aggregateId: taskId, code: "REVISION_MISMATCH", rejectedAt: nil, commandJSON: try command.encodedText())
    }

    private func seed(_ rejection: SyncQueueRepository.Rejection, in db: any PowerSyncDatabaseProtocol) async throws {
        try await db.execute(
            sql: "INSERT INTO sync_rejections (id, command_type, aggregate_id, code, command_json) VALUES (?, ?, ?, ?, ?)",
            parameters: [rejection.id, rejection.commandType, rejection.aggregateId, rejection.code, rejection.commandJSON]
        )
    }

    private func commands(in db: any PowerSyncDatabaseProtocol) async throws -> [[String: JSONPayload]] {
        let archive = try await LocalExportRepository(db: db).archive(context: LocalExportContext(hasSynced: true, lastSyncedAt: nil, connection: "offline"))
        return try archive.pendingCommands.map { try object(#require($0.command)) }
    }

    private func object(_ value: JSONPayload) throws -> [String: JSONPayload] {
        guard case .object(let object) = value else { throw TestError.invalidFixture }
        return object
    }

    private func array(_ value: JSONPayload) throws -> [JSONPayload] {
        guard case .array(let array) = value else { throw TestError.invalidFixture }
        return array
    }

    private func withDatabase(_ work: @MainActor (any PowerSyncDatabaseProtocol) async throws -> Void) async throws {
        let db = LocalDatabase.open(fileName: "rejection-" + UUID().uuidString + ".sqlite")
        do {
            try await work(db)
            try await db.disconnectAndClear()
        } catch {
            try? await db.disconnectAndClear()
            throw error
        }
    }

    private enum TestError: Error { case invalidFixture }
}
