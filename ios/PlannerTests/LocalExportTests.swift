import Foundation
import PowerSync
import Testing
@testable import Planner

/// Each test owns a real, isolated PowerSync SQLite database. No API client, credential store,
/// connection or acknowledgement is involved in exporting it.
@MainActor
struct LocalExportTests {
    private let instant = Date(timeIntervalSince1970: 1_789_646_400)
    private let offline = LocalExportContext(hasSynced: false, lastSyncedAt: nil, connection: "offline")

    @Test func offlineTaskAndEveryChainedCommandAreExportedWithoutAcknowledgingAnything() async throws {
        try await withDatabase { db in
            try await LocalMeta.setServerGeneration("generation-before-restore", in: db)
            let tasks = TaskRepository(db: db)
            var original = TaskDraft()
            original.title = "Créer sans réseau"
            original.notes = "Première note"
            let id = try await tasks.create(original)
            var edited = original
            edited.title = "Titre corrigé hors ligne"
            edited.notes = ""
            try await tasks.update(id, from: original, to: edited)
            try await tasks.setCompleted(id, true)
            let before = try await queueRows(db)
            let repository = LocalExportRepository(db: db)
            let archive = try await repository.archive(context: offline, at: instant)
            let after = try await queueRows(db)

            #expect(before == after)
            #expect(archive.serverGeneration == "generation-before-restore")
            #expect(archive.tasks.count == 1)
            #expect(archive.pendingCommands.count == 3)
            let task = try object(#require(archive.tasks.first))
            #expect(task["id"] == .string(id))
            #expect(task["title"] == .string(edited.title))
            #expect(task["status"] == "completed")
            let commands = try archive.pendingCommands.map { try object(#require($0.command)) }
            #expect(commands.map { $0["type"] } == ["task.create", "task.patch", "task.complete"])
            #expect(commands[0]["precondition"] == nil)
            // TaskRepository.update uses LocalCommand's default .afterPendingCommand. These edits
            // follow an unacknowledged creation of the same task, so both links must survive export.
            for index in 1..<commands.count {
                let previousId = try #require(commands[index - 1]["clientCommandId"])
                #expect(commands[index]["precondition"] == ["kind": "afterCommand", "clientCommandId": previousId])
                #expect(archive.pendingCommands[index].queueSequence > archive.pendingCommands[index - 1].queueSequence)
            }
            let patch = try object(#require(commands[1]["payload"]))
            let set = try object(#require(patch["set"]))
            #expect(set["notes"] == .null)
            #expect(set["priority"] == nil)
            #expect(archive.localState.warnings.contains("INITIAL_SYNC_INCOMPLETE"))
            let data = try archive.encoded()
            let root = try object(JSONDecoder().decode(JSONPayload.self, from: data))
            #expect(root["exportVersion"] == 1)
            #expect(root["localExportVersion"] == 1)
            #expect(root["exportSource"] == "iphone")
        }
    }

    @Test func exportsAllLocalDomainRowsAndTextDraftsButNoPrivateStorageOrAudioPaths() async throws {
        try await withDatabase { db in
            try await db.writeTransaction { tx in
                try tx.execute(sql: "INSERT INTO projects (id, name, deleted_at) VALUES ('list', 'Corbeille', '2026-09-16T10:00:00Z')", parameters: [])
                try tx.execute(sql: """
                    INSERT INTO tasks (id, project_id, title, notes, status, scheduled_date, scheduled_time, scheduled_time_zone,
                      deadline_date, recurrence, deleted_at, search_text) VALUES (
                      'task', 'list', 'À garder', 'Note exportée', 'active', '2026-10-25', '02:30:00', 'Europe/Zurich',
                      NULL, '{"v":1,"mode":"fixed","freq":"daily","interval":1}', '2026-09-16T10:00:00Z', 'DO_NOT_EXPORT_SEARCH_CACHE')
                    """, parameters: [])
                try tx.execute(sql: """
                    INSERT INTO tasks (id, title, status, scheduled_date, deadline_date)
                    VALUES ('zz-date-only', 'Deux dates flottantes', 'active', '2026-10-25', '2026-10-26')
                    """, parameters: [])
                try tx.execute(sql: """
                    INSERT INTO task_occurrences (id, task_id, occurrence_key, status, override_date, successor_occurrence_key)
                    VALUES ('occurrence', 'task', '2026-10-25', 'open', '2026-10-26', NULL)
                    """, parameters: [])
                try tx.execute(sql: "INSERT INTO reminders (id, task_id, kind, offset_minutes, state) VALUES ('reminder', 'task', 'before_start', 30, 'active')", parameters: [])
                try tx.execute(sql: "INSERT INTO conversations (id, title) VALUES ('conversation', 'Historique')", parameters: [])
                try tx.execute(sql: """
                    INSERT INTO messages (id, conversation_id, seq, role, kind, text, original_transcript, transcription_id)
                    VALUES ('message', 'conversation', 1, 'user', 'voice', 'Texte corrigé', 'Transcription initiale', 'transcription')
                    """, parameters: [])
                try tx.execute(sql: "INSERT INTO messages (id, conversation_id, seq, role, kind, text) VALUES ('orphan', 'not-downloaded', 1, 'assistant', 'text', 'Message déjà reçu')", parameters: [])
                try tx.execute(sql: "INSERT INTO sync_rejections (id, command_type, aggregate_id, code, message) VALUES ('rejected', 'task.patch', 'task', 'REVISION_MISMATCH', 'Conflict')", parameters: [])
                try tx.execute(sql: "UPDATE sync_rejections SET command_json = ? WHERE id = 'rejected'", parameters: ["{\"clientCommandId\":\"rejected\",\"type\":\"task.patch\",\"payload\":{\"set\":{\"title\":\"Intention refusée\"}}}"])
                try tx.execute(sql: "INSERT INTO local_meta (id, value) VALUES ('refresh_token', 'DO_NOT_EXPORT_TOKEN'), ('voice_file_name', 'DO_NOT_EXPORT_AUDIO.m4a')", parameters: [])
                try tx.execute(sql: "INSERT INTO assistant_proposals (id, preview) VALUES ('proposal', 'DO_NOT_EXPORT_PLAN')", parameters: [])
                try tx.execute(sql: "INSERT INTO scheduled_notifications (id, trigger_at) VALUES ('DO_NOT_EXPORT_DEVICE_NOTIFICATION', '2026-10-25')", parameters: [])
            }
            let drafts = LocalExportDrafts(
                assistantConversationId: "conversation", assistantText: "Brouillon écrit à conserver",
                voice: LocalExportVoiceText(
                    transcriptionId: "pending-voice", conversationId: "conversation", state: "transcribed",
                    transcript: "Vocal transcrit mais pas envoyé", pendingAssistant: nil
                )
            )
            let before = try await queueRows(db)
            let archive = try await LocalExportRepository(db: db).archive(context: offline, drafts: drafts, at: instant)
            let after = try await queueRows(db)
            #expect(before == after)
            #expect(archive.projects.count == 1)
            #expect(archive.taskOccurrences.count == 1)
            #expect(archive.reminders.count == 1)
            #expect(archive.conversations.count == 1)
            #expect(archive.unlinkedMessages.count == 1)
            #expect(archive.syncRejections.count == 1)
            let rejected = try object(#require(archive.syncRejections.first))
            let rejectedCommand = try object(#require(rejected["command"]))
            #expect(rejectedCommand["payload"] == ["set": ["title": "Intention refusée"]])
            #expect(rejected["storedCommand"] == .string("{\"clientCommandId\":\"rejected\",\"type\":\"task.patch\",\"payload\":{\"set\":{\"title\":\"Intention refusée\"}}}"))
            #expect(archive.pendingCommands.isEmpty) // projection CRUD is not a manual command
            let task = try object(#require(archive.tasks.first))
            #expect(task["schedule"] == ["date": "2026-10-25", "time": "02:30", "timeZone": "Europe/Zurich"])
            #expect(task["deadline"] == .null)
            #expect(task["recurrence"] == ["v": 1, "mode": "fixed", "freq": "daily", "interval": 1])
            #expect(task["deletedAt"] == "2026-09-16T10:00:00Z")
            let floatingTask = try object(#require(archive.tasks.last))
            #expect(floatingTask["schedule"] == ["date": "2026-10-25"])
            #expect(floatingTask["deadline"] == ["date": "2026-10-26"])
            let occurrence = try object(#require(archive.taskOccurrences.first))
            #expect(occurrence["override"] == ["date": "2026-10-26"])
            let conversation = try object(#require(archive.conversations.first))
            let messages = try array(#require(conversation["messages"]))
            let message = try object(#require(messages.first))
            #expect(message["originalTranscript"] == "Transcription initiale")
            let encoded = String(decoding: try archive.encoded(), as: UTF8.self)
            #expect(encoded.contains("Brouillon écrit à conserver"))
            #expect(encoded.contains("Vocal transcrit mais pas envoyé"))
            #expect(!encoded.contains("DO_NOT_EXPORT"))
            #expect(!encoded.contains("ps_crud"))
            #expect(!encoded.contains(".m4a"))
            #expect(archive.localState.warnings.contains("MESSAGES_WITHOUT_LOCAL_CONVERSATION"))
        }
    }

    @Test func futureAndMalformedQueuedPayloadsKeepTheirExactStoredStrings() async throws {
        try await withDatabase { db in
            let exactPayload = #"{ "set": {"notes":null, "title":"un\ntexte"}, "future": true }"#
            let exactPrecondition = #"{ "kind": "afterCommand", "clientCommandId": "previous-command" }"#
            try await db.writeTransaction { tx in
                for (id, payload) in [("future-command", exactPayload), ("broken-command", "{not-json")] {
                    try tx.execute(sql: """
                        INSERT INTO outbox (id, type, payload_version, aggregate_type, aggregate_id, precondition, client_recorded_at, payload)
                        VALUES (?, 'task.future', 99, 'task', 'task', ?, '2026-09-17T10:00:00Z', ?)
                        """, parameters: [id, exactPrecondition, payload])
                }
            }
            let before = try await queueRows(db)
            let archive = try await LocalExportRepository(db: db).archive(context: offline, at: instant)
            let after = try await queueRows(db)
            #expect(before == after)
            #expect(archive.pendingCommands.count == 2)
            let stored = try object(archive.pendingCommands[0].storedCommand)
            #expect(stored["payload"] == .string(exactPayload))
            #expect(stored["precondition"] == .string(exactPrecondition))
            let future = try object(#require(archive.pendingCommands[0].command))
            #expect(future["payloadVersion"] == 99)
            #expect(future["type"] == "task.future")
            #expect(archive.pendingCommands[1].command == nil)
            let malformed = try object(archive.pendingCommands[1].storedCommand)
            #expect(malformed["payload"] == "{not-json")
            #expect(archive.localState.warnings.contains("COMMAND_REQUIRES_RECOVERY"))
        }
    }

    @Test func revokedOrRestoredAndNeverSyncedDevicesStillExport() async throws {
        try await withDatabase { db in
            try await LocalMeta.setServerGeneration("old-generation", in: db)
            try await db.execute(sql: "INSERT INTO server_meta (id, generation) VALUES ('new-generation', 'new-generation')", parameters: [])
            for connection in ["pairing_required", "generation_changed", "offline"] {
                let context = LocalExportContext(hasSynced: nil, lastSyncedAt: nil, connection: connection)
                let archive = try await LocalExportRepository(db: db).archive(context: context, at: instant)
                #expect(archive.serverGeneration == "old-generation")
                #expect(archive.localState.replicatedServerGenerations == ["new-generation"])
                #expect(archive.localState.connection == connection)
                #expect(archive.localState.initialSync == "unknown")
                #expect(archive.localState.warnings.contains("SERVER_GENERATION_CHANGED"))
                #expect(archive.localState.warnings.contains("INITIAL_SYNC_UNKNOWN"))
            }
        }
    }

    @Test func aConcurrentWriterCannotSplitTheProjectionFromItsQueuedCommand() async throws {
        try await withDatabase { db in
            let writer = Task {
                for index in 0..<12 {
                    let command = LocalCommand(type: "task.create", aggregateId: "task-\(index)", chaining: .never, payload: ["title": "Task"])
                    try await db.writeTransaction { tx in
                        try tx.execute(sql: "INSERT INTO tasks (id, title) VALUES (?, 'Task')", parameters: [command.aggregateId])
                        try Outbox.insert(command, in: tx)
                    }
                    await Task.yield()
                }
            }
            do {
                for _ in 0..<12 {
                    let archive = try await LocalExportRepository(db: db).archive(context: offline, at: instant)
                    let tasks = try Set(archive.tasks.map { value in
                        let fields = try object(value)
                        return try #require(fields["id"])
                    })
                    let commands = try Set(archive.pendingCommands.map { entry in
                        let command = try #require(entry.command)
                        let fields = try object(command)
                        let aggregateValue = try #require(fields["aggregate"])
                        let aggregate = try object(aggregateValue)
                        return try #require(aggregate["id"])
                    })
                    #expect(tasks == commands)
                }
                try await writer.value
            } catch {
                writer.cancel()
                _ = try? await writer.value
                throw error
            }
        }
    }

    private func object(_ value: JSONPayload) throws -> [String: JSONPayload] {
        guard case .object(let fields) = value else { throw ExportTestError.expectedObject }
        return fields
    }

    private func array(_ value: JSONPayload) throws -> [JSONPayload] {
        guard case .array(let values) = value else { throw ExportTestError.expectedArray }
        return values
    }

    private func queueRows(_ db: any PowerSyncDatabaseProtocol) async throws -> [String] {
        try await db.getAll(sql: "SELECT data FROM ps_crud ORDER BY id", parameters: []) { cursor in try cursor.getString(index: 0) }
    }

    private func withDatabase(_ work: @MainActor (any PowerSyncDatabaseProtocol) async throws -> Void) async throws {
        let db = LocalDatabase.open(fileName: "local-export-" + UUID().uuidString + ".sqlite")
        do {
            try await work(db)
            try await db.disconnectAndClear()
        } catch {
            try? await db.disconnectAndClear()
            throw error
        }
    }

    private enum ExportTestError: Error { case expectedObject, expectedArray }
}
