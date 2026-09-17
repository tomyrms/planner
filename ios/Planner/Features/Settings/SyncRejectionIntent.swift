import Foundation

/// The archived command is evidence only. This type prepares a new editable intention; it never
/// exposes its original command, reminder IDs or precondition to a write repository.
nonisolated struct SyncRejectionIntent: Sendable {
    nonisolated struct Field: Identifiable, Sendable {
        let id: String
        let title: String
        let value: String
    }

    nonisolated enum PreparationError: Error, Equatable {
        case unsupported, invalidField(String), missingTask, deletedTask

        var message: String {
            switch self {
            case .unsupported: "Cette demande ne peut pas être préremplie par cette version de l’app. Ses valeurs restent consultables et exportables."
            case .invalidField(let field): "Le champ « \(field) » ne peut pas être repris sans perte. Consultez ses valeurs ci-dessous ; le rejet reste exportable."
            case .missingTask: "La tâche n’est pas présente sur cet iPhone. Attendez la synchronisation ou utilisez les valeurs conservées pour créer une nouvelle tâche."
            case .deletedTask: "La tâche est dans la Corbeille. Restaurez-la explicitement avant de la modifier."
            }
        }
    }

    let type: String
    let aggregateType: String
    let aggregateId: String
    let version: Int
    let payload: [String: JSONPayload]
    let dependsOn: String?

    init?(rejection: SyncQueueRepository.Rejection) {
        guard let text = rejection.commandJSON, let json = try? JSONPayload.decode(text),
              case .object(let command) = json,
              case .string(let id) = command["clientCommandId"], id.lowercased() == rejection.id.lowercased(),
              case .string(let type) = command["type"], type == rejection.commandType,
              case .int(let version) = command["payloadVersion"],
              case .object(let aggregate) = command["aggregate"],
              case .string(let aggregateType) = aggregate["type"],
              case .string(let aggregateId) = aggregate["id"], aggregateId.lowercased() == rejection.aggregateId.lowercased()
        else { return nil }
        if let value = command["payload"] {
            guard case .object(let payload) = value else { return nil }
            self.payload = payload
        } else {
            payload = [:]
        }
        self.type = type
        self.aggregateType = aggregateType
        self.aggregateId = aggregateId
        self.version = version
        if case .object(let condition) = command["precondition"], condition["kind"] == "afterCommand",
           case .string(let id) = condition["clientCommandId"] {
            dependsOn = id
        } else { dependsOn = nil }
    }

    var supportsEditor: Bool { version == 1 && aggregateType == "task" && (type == "task.create" || type == "task.patch") }

    var actionTitle: String {
        let titles = [
            "task.create": "Création d’une tâche", "task.patch": "Modification d’une tâche",
            "task.complete": "Tâche terminée", "task.reopen": "Tâche rouverte",
            "task.delete": "Suppression d’une tâche", "task.restore": "Restauration d’une tâche",
            "task.subtask.add": "Ajout d’une sous-tâche", "task.subtask.patch": "Modification d’une sous-tâche",
            "task.subtask.remove": "Retrait d’une sous-tâche", "task.tag.add": "Ajout d’un tag à la tâche",
            "task.tag.remove": "Retrait d’un tag de la tâche", "tag.create": "Création d’un tag",
            "tag.patch": "Modification d’un tag", "tag.delete": "Suppression d’un tag", "tag.restore": "Restauration d’un tag",
            "settings.patch": "Modification des paramètres de l’assistant",
            "occurrence.complete": "Occurrence terminée", "occurrence.skip": "Occurrence ignorée",
            "occurrence.reopen": "Occurrence rouverte", "occurrence.reschedule": "Déplacement d’une occurrence",
            "occurrence.skip_missed_before": "Occurrences manquées ignorées",
            "series.update": "Modification de toute la série", "series.end": "Arrêt d’une série",
            "reminder.set": "Création ou modification d’un rappel", "reminder.remove": "Suppression d’un rappel",
            "project.create": "Création d’une liste", "project.patch": "Modification d’une liste",
            "project.archive": "Archivage d’une liste", "project.unarchive": "Liste désarchivée",
            "project.delete": "Suppression d’une liste", "project.restore": "Restauration d’une liste",
        ]
        return titles[type] ?? "Action conservée, non prise en charge par cette version"
    }

    var patchFields: Set<String> {
        if type == "task.patch", case .object(let set) = payload["set"] { return Set(set.keys) }
        return []
    }

    /// Absent fields keep their current values; explicit null removes the value. An unrepresentable
    /// field blocks prefill rather than silently dropping part of the refused request.
    func prefilledDraft(current: TaskDraft? = nil) throws -> TaskDraft {
        guard supportsEditor else { throw PreparationError.unsupported }
        let values: [String: JSONPayload]
        var draft: TaskDraft
        if type == "task.create" {
            values = payload
            draft = TaskDraft()
        } else {
            guard let current else { throw PreparationError.missingTask }
            guard payload.count == 1, case .object(let set) = payload["set"], !set.isEmpty else { throw PreparationError.unsupported }
            values = set
            draft = current
            if current.recurrence != nil, set["deadline"] != nil {
                throw PreparationError.invalidField("Échéance d’une tâche répétée")
            }
        }
        let allowed: Set<String> = ["title", "notes", "priority", "projectId", "schedule", "deadline", "durationMinutes"]
        for (key, value) in values {
            guard allowed.contains(key) || (type == "task.create" && ["recurrence", "reminders", "subtasks", "tagIds"].contains(key)) else {
                throw PreparationError.invalidField(Self.name(key))
            }
            switch key {
            case "title": draft.title = try Self.string(value, key: key)
            case "notes": draft.notes = value == .null ? "" : try Self.string(value, key: key)
            case "priority":
                guard let priority = Priority(rawValue: try Self.string(value, key: key)) else { throw PreparationError.invalidField(Self.name(key)) }
                draft.priority = priority
            case "projectId": draft.projectId = value == .null ? nil : try Self.string(value, key: key)
            case "schedule": draft.schedule = value == .null ? nil : try Self.time(value, key: key)
            case "deadline": draft.deadline = value == .null ? nil : try Self.time(value, key: key)
            case "durationMinutes":
                if value == .null { draft.durationMinutes = nil }
                else if case .int(let minutes) = value, (1...1440).contains(minutes) { draft.durationMinutes = minutes }
                else { throw PreparationError.invalidField(Self.name(key)) }
            case "recurrence":
                if value == .null { draft.recurrence = nil }
                else {
                    draft.recurrence = try Self.recurrence(value)
                }
            case "reminders":
                guard case .array(let reminders) = value, reminders.count <= 1 else { throw PreparationError.invalidField(Self.name(key)) }
                if let first = reminders.first {
                    guard case .object(let reminder) = first,
                          Set(reminder.keys).isSubset(of: ["id", "rule", "occurrenceKey"]),
                          reminder["occurrenceKey"] == nil || reminder["occurrenceKey"] == .null,
                          let value = reminder["rule"] else { throw PreparationError.invalidField(Self.name(key)) }
                    draft.reminder = try Self.reminder(value)
                }
                draft.reminderId = nil // create() generates a new identifier for the new reminder.
            case "subtasks":
                guard case .array(let rows) = value, rows.count <= 50 else { throw PreparationError.invalidField(Self.name(key)) }
                var sourceIds: Set<String> = []
                draft.subtasks = try rows.enumerated().map { index, row in
                    guard case .object(let fields) = row,
                          Set(fields.keys).isSubset(of: ["id", "title", "isCompleted", "sortOrder"]),
                          case .string(let id) = fields["id"], UUID(uuidString: id) != nil,
                          sourceIds.insert(id.lowercased()).inserted,
                          case .string(let title) = fields["title"] else { throw PreparationError.invalidField(Self.name(key)) }
                    let completed: Bool
                    if let value = fields["isCompleted"] {
                        guard case .bool(let flag) = value else { throw PreparationError.invalidField(Self.name(key)) }
                        completed = flag
                    } else { completed = false }
                    let order: Double
                    switch fields["sortOrder"] {
                    case .int(let value): order = Double(value)
                    case .double(let value): order = value
                    case nil: order = Double(index)
                    default: throw PreparationError.invalidField(Self.name(key))
                    }
                    // This is a new task; subtask identities are recreated along with its task identity.
                    return TaskSubtask(title: title, isCompleted: completed, sortOrder: order)
                }
                guard TaskSubtask.areValid(draft.subtasks) else { throw PreparationError.invalidField(Self.name(key)) }
            case "tagIds":
                guard case .array(let values) = value, values.count <= 10 else { throw PreparationError.invalidField(Self.name(key)) }
                let ids = try values.map { value in
                    let id = try Self.string(value, key: key)
                    guard UUID(uuidString: id) != nil else { throw PreparationError.invalidField(Self.name(key)) }
                    return id.lowercased()
                }
                guard Set(ids).count == ids.count else { throw PreparationError.invalidField(Self.name(key)) }
                draft.tagIds = Set(ids)
            default: break
            }
        }
        if draft.recurrence != nil, draft.deadline != nil { throw PreparationError.invalidField("Échéance d’une tâche répétée") }
        if draft.recurrence != nil, draft.schedule == nil { throw PreparationError.invalidField("Planification d’une tâche répétée") }
        if draft.recurrence != nil, !draft.subtasks.isEmpty { throw PreparationError.invalidField("Sous-tâches d’une tâche répétée") }
        return draft
    }

    var fields: [Field] {
        let values: [String: JSONPayload]
        if case .object(let set) = payload["set"] {
            values = payload.filter { $0.key != "set" }.merging(set, uniquingKeysWith: { _, last in last })
        } else { values = payload }
        return values.keys.sorted().map { key in
            let value = values[key] ?? .null
            let description: String
            if key == "priority", case .string(let raw) = value, let priority = Priority(rawValue: raw) {
                description = priority.label
            } else if key == "rule", let rule = try? Self.reminder(value) {
                description = rule.label
            } else if key == "taskPolicy", value == "move_tasks_to_inbox" {
                description = "Déplacer les tâches vers Inbox"
            } else if key == "taskPolicy", value == "trash_tasks_with_project" {
                description = "Mettre les tâches à la Corbeille avec la liste"
            } else { description = Self.describe(value, depth: 0) }
            return Field(id: key, title: Self.name(key), value: description)
        }
    }

    private static func string(_ value: JSONPayload, key: String) throws -> String {
        guard case .string(let text) = value else { throw PreparationError.invalidField(name(key)) }
        return text
    }

    private static func time(_ value: JSONPayload, key: String) throws -> TimeValue {
        guard case .object(let object) = value, Set(object.keys).isSubset(of: ["date", "time", "timeZone"]),
              case .string(let text) = object["date"], let date = CivilDate(text), date.description == text,
              (1...9999).contains(date.year), date.day <= CivilDate.monthLength(year: date.year, month: date.month) else {
            throw PreparationError.invalidField(name(key))
        }
        let hasTime = object["time"] != nil && object["time"] != .null
        if !hasTime {
            guard object["timeZone"] == nil || object["timeZone"] == .null else { throw PreparationError.invalidField(name(key)) }
            return TimeValue(date: date)
        }
        guard case .string(let text) = object["time"], let time = LocalTime(text), time.description == text,
              case .string(let zone) = object["timeZone"], TimeZone(identifier: zone) != nil else { throw PreparationError.invalidField(name(key)) }
        return TimeValue(date: date, time: time, timeZone: zone)
    }

    private static func reminder(_ value: JSONPayload) throws -> ReminderRule {
        guard case .object(let object) = value, case .string(let kind) = object["kind"] else { throw PreparationError.invalidField("Rappel") }
        let rule: ReminderRule
        switch kind {
        case "before_start", "before_deadline":
            guard case .int(let minutes) = object["offsetMinutes"], (0...10080).contains(minutes) else { throw PreparationError.invalidField("Rappel") }
            rule = kind == "before_start" ? .beforeStart(minutes: minutes) : .beforeDeadline(minutes: minutes)
        case "on_scheduled_day_at", "on_deadline_day_at":
            guard case .string(let text) = object["localTime"], let time = LocalTime(text), time.description == text else { throw PreparationError.invalidField("Rappel") }
            rule = kind == "on_scheduled_day_at" ? .onScheduledDay(time) : .onDeadlineDay(time)
        case "absolute":
            guard let value = object["absolute"] else { throw PreparationError.invalidField("Rappel") }
            let time = try time(value, key: "reminders")
            guard time.time != nil else { throw PreparationError.invalidField("Rappel") }
            rule = .absolute(time)
        default: throw PreparationError.invalidField("Rappel")
        }
        guard rule.payload == value else { throw PreparationError.invalidField("Rappel") }
        return rule
    }

    private static func recurrence(_ value: JSONPayload) throws -> RecurrenceRule {
        guard case .object(let object) = value, object["v"] == 1,
              case .int(let interval) = object["interval"], (1...365).contains(interval) else {
            throw PreparationError.invalidField("Répétition")
        }
        if let value = object["count"] {
            guard case .int(let count) = value, (1...3_652_059).contains(count) else { throw PreparationError.invalidField("Répétition") }
        }
        if let value = object["byMonthDay"] {
            guard case .int(let day) = value, (1...31).contains(day) else { throw PreparationError.invalidField("Répétition") }
        }
        if let value = object["until"] { _ = try time(["date": value], key: "recurrence") }
        guard let rule = RecurrenceRule(object: object), rule.payload == value else { throw PreparationError.invalidField("Répétition") }
        return rule
    }

    private static func describe(_ value: JSONPayload, depth: Int) -> String {
        guard depth < 5 else { return "Détail conservé dans l’export" }
        switch value {
        case .null: return "Effacer cette valeur"
        case .string(let text): return text.isEmpty ? "Texte vide" : text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let value): return value ? "Oui" : "Non"
        case .array(let values): return values.isEmpty ? "Aucun" : values.map { describe($0, depth: depth + 1) }.joined(separator: "\n")
        case .object(let object):
            return object.keys.sorted().map { "\(name($0)) : \(describe(object[$0] ?? .null, depth: depth + 1))" }.joined(separator: "\n")
        }
    }

    private static func name(_ key: String) -> String {
        let names = [
            "title": "Titre", "notes": "Description", "priority": "Priorité", "projectId": "Liste (identifiant)",
            "subtasks": "Sous-tâches", "subtask": "Sous-tâche", "subtaskId": "Sous-tâche (identifiant)",
            "isCompleted": "Terminée", "tagIds": "Tags (identifiants)", "tagId": "Tag (identifiant)", "autoTags": "Tags automatiques",
            "schedule": "Planification", "deadline": "Échéance", "durationMinutes": "Durée en minutes",
            "recurrence": "Répétition", "reminders": "Rappels", "rule": "Règle du rappel", "id": "Identifiant",
            "occurrenceKey": "Occurrence", "actionLocalDate": "Date de l’action", "name": "Nom",
            "taskPolicy": "Devenir des tâches", "colorKey": "Couleur", "sortOrder": "Ordre",
            "date": "Date", "time": "Heure", "timeZone": "Fuseau", "kind": "Type", "offsetMinutes": "Minutes avant",
            "localTime": "Heure locale", "absolute": "Date et heure", "freq": "Fréquence", "interval": "Intervalle",
            "mode": "Mode", "unit": "Unité", "byWeekday": "Jours", "byMonthDay": "Jour du mois",
            "lastDayOfMonth": "Dernier jour du mois", "until": "Jusqu’au", "count": "Nombre d’occurrences", "v": "Version",
        ]
        return names[key] ?? key
    }
}
