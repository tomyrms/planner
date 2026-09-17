import Foundation
import PowerSync

nonisolated enum TaskTagIdentity {
    static let namespace = UUID(uuidString: "04c55814-dde2-539b-92f2-91a16b669f2f")!
    static func id(taskId: String, tagId: String) -> String {
        OccurrenceKey.uuidV5(namespace: namespace, name: "\(taskId.lowercased())/\(tagId.lowercased())").uuidString.lowercased()
    }
}

nonisolated extension TaskRepository {
    func observeTags() throws -> AsyncThrowingStream<[TagItem], any Error> {
        try db.watch(sql: "SELECT id, name, deleted_at FROM tags ORDER BY deleted_at IS NOT NULL, name COLLATE NOCASE, id", parameters: []) {
            TagItem(id: try $0.getString(name: "id"), name: try $0.getString(name: "name"), deletedAt: Timestamp.parse(try $0.getStringOptional(name: "deleted_at")))
        }
    }

    /// Includes links to deleted tags: deleting a catalogue tag must not silently remove assignments.
    func observeTagIds(taskId: String) throws -> AsyncThrowingStream<[String], any Error> {
        try db.watch(sql: "SELECT tag_id FROM task_tags WHERE task_id = ? AND deleted_at IS NULL ORDER BY tag_id", parameters: [taskId]) {
            try $0.getString(index: 0)
        }
    }

    @discardableResult
    func createTag(name: String) async throws -> String {
        let id = UUID().uuidString.lowercased()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Timestamp.format(Date())
        try await db.writeTransaction { tx in
            try Self.validateTagName(name, excluding: nil, in: tx)
            try Self.requireTagCapacity(in: tx)
            try tx.execute(sql: "INSERT INTO tags (id, name, normalized_name, revision, created_at, updated_at) VALUES (?, ?, ?, 0, ?, ?)", parameters: [id, name, TagItem.normalizedName(name), now, now])
            try Outbox.insert(LocalCommand(type: "tag.create", aggregateType: "tag", aggregateId: id, chaining: .never, payload: ["name": .string(name)]), in: tx)
        }
        return id
    }

    func renameTag(_ id: String, name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await db.writeTransaction { tx in
            try Self.requireActiveTag(id, in: tx)
            try Self.validateTagName(name, excluding: id, in: tx)
            try tx.execute(sql: "UPDATE tags SET name = ?, normalized_name = ?, updated_at = ? WHERE id = ?", parameters: [name, TagItem.normalizedName(name), Timestamp.format(Date()), id])
            try Outbox.insert(LocalCommand(type: "tag.patch", aggregateType: "tag", aggregateId: id, payload: ["set": ["name": .string(name)]]), in: tx)
        }
    }

    func setTagDeleted(_ id: String, _ deleted: Bool) async throws {
        try await db.writeTransaction { tx in
            let stored = try tx.getOptional(sql: "SELECT name, deleted_at FROM tags WHERE id = ?", parameters: [id]) {
                (name: try $0.getString(index: 0), deleted: $0.getStringOptional(index: 1) != nil)
            }
            guard let tag = stored else { throw TaskDetailsError.unavailableTag }
            guard tag.deleted != deleted else { return }
            if !deleted {
                try Self.validateTagName(tag.name, excluding: id, in: tx)
                try Self.requireTagCapacity(in: tx)
                let fullTask = try tx.getOptional(sql: """
                    SELECT link.task_id FROM task_tags link
                    WHERE link.tag_id = ? AND link.deleted_at IS NULL AND
                        (SELECT count(*) FROM task_tags existing JOIN tags t ON t.id = existing.tag_id
                         WHERE existing.task_id = link.task_id AND existing.deleted_at IS NULL AND t.deleted_at IS NULL) >= 10
                    LIMIT 1
                    """, parameters: [id]) { try $0.getString(index: 0) }
                guard fullTask == nil else { throw TaskDetailsError.taskTagLimit }
            }
            let now = Timestamp.format(Date())
            try tx.execute(sql: "UPDATE tags SET deleted_at = ?, updated_at = ? WHERE id = ?", parameters: [deleted ? now : nil, now, id])
            try Outbox.insert(LocalCommand(type: deleted ? "tag.delete" : "tag.restore", aggregateType: "tag", aggregateId: id), in: tx)
        }
    }

    /// Missing settings mean disabled. Ownership is read from local pairing metadata, never chosen by the UI.
    func observeAutoTags() throws -> AsyncThrowingStream<[Bool], any Error> {
        try db.watch(sql: """
            SELECT coalesce((SELECT auto_tags FROM user_settings WHERE id =
                (SELECT value FROM local_meta WHERE id = 'owner_user_id')), 0)
            """, parameters: []) { try $0.getInt(index: 0) == 1 }
    }

    func assistantSettingsSyncState() async throws -> (pending: Bool, rejected: Bool) {
        try await db.get(sql: """
            SELECT EXISTS(SELECT 1 FROM ps_crud WHERE json_extract(data, '$.type') = 'outbox'
                AND json_extract(data, '$.data.type') = 'settings.patch'),
                EXISTS(SELECT 1 FROM sync_rejections WHERE command_type = 'settings.patch')
            """, parameters: []) { (pending: try $0.getInt(index: 0) == 1, rejected: try $0.getInt(index: 1) == 1) }
    }

    func setAutoTags(_ enabled: Bool) async throws {
        try await db.writeTransaction { tx in
            let storedOwner = try tx.getOptional(sql: "SELECT value FROM local_meta WHERE id = ?", parameters: [LocalMeta.ownerUserIdKey]) { try $0.getString(index: 0) }
            guard let owner = storedOwner,
                  UUID(uuidString: owner) != nil else { throw TaskDetailsError.missingOwner }
            let exists = try tx.getOptional(sql: "SELECT auto_tags FROM user_settings WHERE id = ?", parameters: [owner]) { try $0.getInt(index: 0) }
            guard exists != (enabled ? 1 : 0) else { return }
            let now = Timestamp.format(Date())
            if exists != nil {
                try tx.execute(sql: "UPDATE user_settings SET auto_tags = ?, updated_at = ? WHERE id = ?", parameters: [enabled ? 1 : 0, now, owner])
            } else {
                try tx.execute(sql: "INSERT INTO user_settings (id, auto_tags, revision, created_at, updated_at) VALUES (?, ?, 0, ?, ?)", parameters: [owner, enabled ? 1 : 0, now, now])
            }
            try Outbox.insert(LocalCommand(type: "settings.patch", aggregateType: "settings", aggregateId: owner, payload: ["set": ["autoTags": .bool(enabled)]]), in: tx)
        }
    }

    static func validateDetails(_ draft: TaskDraft, creating: Bool = false) throws {
        guard draft.recurrence == nil || draft.subtasks.isEmpty else { throw TaskDetailsError.recurringSubtasks }
        guard draft.subtasks.count <= 50 else { throw TaskDetailsError.subtaskLimit }
        guard !creating || draft.tagIds.count <= 10 else { throw TaskDetailsError.taskTagLimit }
        guard draft.isValid, draft.isValidSeries,
              Set(draft.tagIds.map { $0.lowercased() }).count == draft.tagIds.count else { throw TaskDetailsError.invalidDraft }
    }

    static func insertInitialDetails(taskId: String, draft: TaskDraft, now: String, in tx: any Transaction) throws {
        try tx.execute(sql: "UPDATE tasks SET subtasks = ? WHERE id = ?", parameters: [try subtaskText(draft.subtasks), taskId])
        for tagId in draft.tagIds.sorted() {
            try requireActiveTag(tagId, in: tx)
            try writeTagLink(taskId: taskId, tagId: tagId, removed: false, now: now, in: tx)
        }
    }

    /// Diffs the edited IDs against the latest local projection. Other devices' unrelated rows/fields survive.
    /// All calls run inside the parent editor transaction, so a refused detail rolls back the whole save.
    static func writeDetails(taskId: String, from base: TaskDraft, to draft: TaskDraft, in tx: any Transaction) throws {
        guard base.subtasks != draft.subtasks || base.tagIds != draft.tagIds else { return }
        let storedTask = try tx.getOptional(sql: "SELECT \(TaskItem.selectColumns) FROM tasks WHERE id = ? AND deleted_at IS NULL", parameters: [taskId]) { try TaskItem(row: $0) }
        guard let task = storedTask else { throw TaskDetailsError.missingTask }
        if base.subtasks != draft.subtasks {
            guard !task.isRecurring else { throw TaskDetailsError.recurringSubtasks }
            guard TaskSubtask.areValid(base.subtasks) else { throw TaskDetailsError.invalidDraft }
            var rows = task.subtasks
            let previous = Dictionary(uniqueKeysWithValues: base.subtasks.map { ($0.id.lowercased(), $0) })
            let proposed = Dictionary(uniqueKeysWithValues: draft.subtasks.map { ($0.id.lowercased(), $0) })
            let reorders = draft.subtasks.contains { row in previous[row.id.lowercased()].map { $0.sortOrder != row.sortOrder } ?? false }
            let chaining: LocalCommand.Chaining = reorders ? .required(revision: base.sourceRevision) : .afterPendingCommand
            for removed in base.subtasks where proposed[removed.id.lowercased()] == nil {
                rows.removeAll { $0.id.lowercased() == removed.id.lowercased() }
                try Outbox.insert(LocalCommand(type: "task.subtask.remove", aggregateId: taskId, chaining: chaining, payload: ["subtaskId": .string(removed.id.lowercased())]), in: tx)
            }
            for subtask in draft.subtasks {
                let id = subtask.id.lowercased()
                if let old = previous[id] {
                    var set: [String: JSONPayload] = [:]
                    if old.trimmedTitle != subtask.trimmedTitle { set["title"] = .string(subtask.trimmedTitle) }
                    if old.isCompleted != subtask.isCompleted { set["isCompleted"] = .bool(subtask.isCompleted) }
                    if old.sortOrder != subtask.sortOrder { set["sortOrder"] = .double(subtask.sortOrder) }
                    guard !set.isEmpty else { continue }
                    guard let index = rows.firstIndex(where: { $0.id.lowercased() == id }) else { throw TaskDetailsError.missingSubtask }
                    if set["title"] != nil { rows[index].title = subtask.trimmedTitle }
                    if set["isCompleted"] != nil { rows[index].isCompleted = subtask.isCompleted }
                    if set["sortOrder"] != nil { rows[index].sortOrder = subtask.sortOrder }
                    try Outbox.insert(LocalCommand(type: "task.subtask.patch", aggregateId: taskId, chaining: chaining, payload: ["subtaskId": .string(id), "set": .object(set)]), in: tx)
                } else {
                    guard !rows.contains(where: { $0.id.lowercased() == id }) else { throw TaskDetailsError.duplicateSubtask }
                    rows.append(subtask)
                    guard rows.count <= 50 else { throw TaskDetailsError.subtaskLimit }
                    try Outbox.insert(LocalCommand(type: "task.subtask.add", aggregateId: taskId, chaining: chaining, payload: ["subtask": subtask.payload]), in: tx)
                }
            }
            try tx.execute(sql: "UPDATE tasks SET subtasks = ?, updated_at = ? WHERE id = ?", parameters: [try subtaskText(rows), Timestamp.format(Date()), taskId])
        }
        let now = Timestamp.format(Date())
        for tagId in base.tagIds.subtracting(draft.tagIds).sorted() {
            try writeTagLink(taskId: taskId, tagId: tagId, removed: true, now: now, in: tx)
            try Outbox.insert(LocalCommand(type: "task.tag.remove", aggregateId: taskId, payload: ["tagId": .string(tagId)]), in: tx)
        }
        for tagId in draft.tagIds.subtracting(base.tagIds).sorted() {
            try requireActiveTag(tagId, in: tx)
            let alreadyAssigned = try tx.getOptional(sql: "SELECT 1 FROM task_tags WHERE task_id = ? AND tag_id = ? AND deleted_at IS NULL", parameters: [taskId, tagId]) { try $0.getInt(index: 0) } != nil
            let count = try tx.get(sql: "SELECT count(*) FROM task_tags tt JOIN tags t ON t.id = tt.tag_id WHERE tt.task_id = ? AND tt.deleted_at IS NULL AND t.deleted_at IS NULL", parameters: [taskId]) { try $0.getInt(index: 0) }
            guard alreadyAssigned || count < 10 else { throw TaskDetailsError.taskTagLimit }
            try writeTagLink(taskId: taskId, tagId: tagId, removed: false, now: now, in: tx)
            try Outbox.insert(LocalCommand(type: "task.tag.add", aggregateId: taskId, payload: ["tagId": .string(tagId)]), in: tx)
        }
    }

    private static func subtaskText(_ rows: [TaskSubtask]) throws -> String {
        try JSONPayload.array(TaskSubtask.sorted(rows).map(\.payload)).encodedText()
    }

    private static func writeTagLink(taskId: String, tagId: String, removed: Bool, now: String, in tx: any Transaction) throws {
        let id = TaskTagIdentity.id(taskId: taskId, tagId: tagId)
        let exists = try tx.getOptional(sql: "SELECT id FROM task_tags WHERE id = ?", parameters: [id]) { try $0.getString(index: 0) } != nil
        if exists {
            try tx.execute(sql: "UPDATE task_tags SET deleted_at = ?, updated_at = ? WHERE id = ?", parameters: [removed ? now : nil, now, id])
        } else {
            try tx.execute(sql: "INSERT INTO task_tags (id, task_id, tag_id, deleted_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)", parameters: [id, taskId.lowercased(), tagId.lowercased(), removed ? now : nil, now, now])
        }
    }

    private static func requireActiveTag(_ id: String, in tx: any Transaction) throws {
        let existing = try tx.getOptional(sql: "SELECT id FROM tags WHERE id = ? AND deleted_at IS NULL", parameters: [id.lowercased()]) { try $0.getString(index: 0) }
        guard existing != nil else { throw TaskDetailsError.unavailableTag }
    }

    private static func requireTagCapacity(in tx: any Transaction) throws {
        let count = try tx.get(sql: "SELECT count(*) FROM tags WHERE deleted_at IS NULL", parameters: []) { try $0.getInt(index: 0) }
        guard count < 200 else { throw TaskDetailsError.tagLimit }
    }

    private static func validateTagName(_ name: String, excluding id: String?, in tx: any Transaction) throws {
        guard !name.isEmpty, name.utf16.count <= 50 else { throw TaskDetailsError.invalidTagName }
        // SQLite NOCASE is ASCII-only. Preserve accents while folding Unicode case and canonical forms.
        let names = try tx.getAll(sql: "SELECT id, name FROM tags WHERE deleted_at IS NULL", parameters: []) {
            (id: try $0.getString(index: 0), name: try $0.getString(index: 1))
        }
        guard !names.contains(where: { $0.id != id && TagItem.normalizedName($0.name) == TagItem.normalizedName(name) }) else { throw TaskDetailsError.duplicateTagName }
    }
}
