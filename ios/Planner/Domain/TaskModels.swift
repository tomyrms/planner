import Foundation

nonisolated enum Priority: String, CaseIterable, Identifiable, Sendable {
    // "none" is spelled `unset` so that it never reads as `Optional.none`.
    case unset = "none"
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unset: "Aucune"
        case .low: "Basse"
        case .medium: "Moyenne"
        case .high: "Haute"
        }
    }
}

/// A task as the screens see it (04_Backend/03_Data_Model.md). For a series, `isCompleted` means "series ended".
nonisolated struct TaskItem: Identifiable, Hashable, Sendable {
    let id: String
    var projectId: String?
    var title: String
    var notes: String?
    var priority: Priority
    var isCompleted: Bool
    var completedAt: Date?
    var schedule: TimeValue?
    var durationMinutes: Int?
    var deadline: TimeValue?
    var recurrence: RecurrenceRule?
    var missedIgnoredBefore: CivilDate?
    var deletedAt: Date?
    var revision: Int
    var createdAt: Date?
    var subtasks: [TaskSubtask] = []

    var isDeleted: Bool { deletedAt != nil }
    var isRecurring: Bool { recurrence != nil }
}

/// A materialized occurrence of a series (only occurrences with a state or a move exist).
nonisolated struct OccurrenceRow: Hashable, Sendable {
    let taskId: String
    let key: String
    var status: OccurrenceStatus
    var completedAt: Date?
    var override: TimeValue?
    var successorKey: String?
}

/// A reminder as replicated (deleted reminders leave the replica).
nonisolated struct ReminderRow: Identifiable, Hashable, Sendable {
    let id: String
    let taskId: String
    let occurrenceKey: String?
    let rule: ReminderRule
    let baseMissing: Bool
}

nonisolated struct ProjectItem: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var activeTaskCount: Int
}

/// Which tasks a screen observes.
nonisolated enum TaskFilter: Hashable, Sendable {
    /// All active tasks and running series; completed/deleted tasks have their own destinations.
    case allActive
    case inbox
    case project(String)
    /// Active tasks with a planned or due date, series included (Today, Upcoming, Calendar).
    case dated
    case completed
    case trash
    case search(String)
}

/// Fields of the editor; the repository turns the differences into one `task.patch`.
nonisolated struct TaskDraft: Equatable, Sendable {
    var title: String = ""
    var notes: String = ""
    var priority: Priority = .unset
    var projectId: String?
    var schedule: TimeValue?
    var deadline: TimeValue?
    var durationMinutes: Int?
    /// Only at creation: the command catalogue has no way to turn a simple task into a series later.
    var recurrence: RecurrenceRule?
    /// The single reminder of the V1 editor, and its identifier once saved.
    var reminder: ReminderRule?
    var reminderId: String?
    var subtasks: [TaskSubtask] = []
    var tagIds: Set<String> = []
    var sourceRevision = 0

    init() {}

    init(task: TaskItem, reminder: ReminderRow? = nil, tagIds: Set<String> = []) {
        self.reminder = reminder?.rule
        reminderId = reminder?.id
        title = task.title
        notes = task.notes ?? ""
        priority = task.priority
        projectId = task.projectId
        schedule = task.schedule
        deadline = task.deadline
        durationMinutes = task.durationMinutes
        recurrence = task.recurrence
        subtasks = task.subtasks
        self.tagIds = tagIds
        sourceRevision = task.revision
    }

    /// A series needs a planned date and has no deadline in V1.
    var isValidSeries: Bool {
        recurrence == nil || (schedule != nil && deadline == nil && subtasks.isEmpty)
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool {
        !trimmedTitle.isEmpty && trimmedTitle.count <= 500 && notes.count <= 10_000
            && TaskSubtask.areValid(subtasks)
            && tagIds.allSatisfy { UUID(uuidString: $0) != nil }
    }

    /// `set` of a `task.patch`: only the fields that differ from `base`; `null` clears a field.
    func changes(from base: TaskDraft) -> [String: JSONPayload] {
        var set: [String: JSONPayload] = [:]
        if trimmedTitle != base.trimmedTitle { set["title"] = .string(trimmedTitle) }
        if notes != base.notes { set["notes"] = notes.isEmpty ? .null : .string(notes) }
        if priority != base.priority { set["priority"] = .string(priority.rawValue) }
        if projectId != base.projectId { set["projectId"] = projectId.map { JSONPayload.string($0) } ?? .null }
        if schedule != base.schedule { set["schedule"] = schedule?.payload ?? .null }
        if deadline != base.deadline { set["deadline"] = deadline?.payload ?? .null }
        if durationMinutes != base.durationMinutes { set["durationMinutes"] = durationMinutes.map { JSONPayload.int($0) } ?? .null }
        return set
    }
}

/// Search normalization shared with the backend (04_Backend/03_Data_Model.md §9):
/// NFKD, marks removed, lowercase, anything but letters, digits, "#", "+", "-", "." becomes one space.
nonisolated enum SearchText {
    static func normalize(_ parts: [String?]) -> String {
        let joined = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in joined.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            if isMark(scalar) { continue }
            if isKept(scalar) {
                if pendingSpace && !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return String(result)
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    private static func isKept(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            "#+-.".unicodeScalars.contains(scalar)
        }
    }
}
