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

/// A task as the screens see it (04_Backend/03_Data_Model.md). Recurring occurrences arrive at step 6.
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
    var isRecurring: Bool
    var deletedAt: Date?
    var revision: Int
    var createdAt: Date?

    var isDeleted: Bool { deletedAt != nil }
}

nonisolated struct ProjectItem: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var activeTaskCount: Int
}

/// Which tasks a screen observes.
nonisolated enum TaskFilter: Hashable, Sendable {
    case inbox
    case project(String)
    /// Active, non-recurring tasks with a planned or due date (Today, Upcoming).
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

    init() {}

    init(task: TaskItem) {
        title = task.title
        notes = task.notes ?? ""
        priority = task.priority
        projectId = task.projectId
        schedule = task.schedule
        deadline = task.deadline
        durationMinutes = task.durationMinutes
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { !trimmedTitle.isEmpty && trimmedTitle.count <= 500 && notes.count <= 10_000 }

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
