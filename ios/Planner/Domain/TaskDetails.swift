import Foundation

nonisolated struct TaskSubtask: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var isCompleted: Bool
    var sortOrder: Double

    init(id: String = UUID().uuidString.lowercased(), title: String, isCompleted: Bool = false, sortOrder: Double = 0) {
        self.id = id.lowercased()
        self.title = title
        self.isCompleted = isCompleted
        self.sortOrder = sortOrder
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var payload: JSONPayload {
        ["id": .string(id.lowercased()), "title": .string(trimmedTitle), "isCompleted": .bool(isCompleted), "sortOrder": .double(sortOrder)]
    }

    static func areValid(_ values: [TaskSubtask]) -> Bool {
        values.count <= 50 && Set(values.map { $0.id.lowercased() }).count == values.count
            && values.allSatisfy { UUID(uuidString: $0.id) != nil && !$0.trimmedTitle.isEmpty && $0.trimmedTitle.utf16.count <= 500 && $0.sortOrder.isFinite }
    }

    static func sorted(_ values: [TaskSubtask]) -> [TaskSubtask] {
        values.sorted { $0.sortOrder == $1.sortOrder ? $0.id.lowercased() < $1.id.lowercased() : $0.sortOrder < $1.sortOrder }
    }

    /// Native list destination is measured before removing the source rows.
    static func moving(_ values: [TaskSubtask], from source: IndexSet, to destination: Int) -> [TaskSubtask] {
        guard !source.isEmpty, source.allSatisfy({ values.indices.contains($0) }), (0...values.count).contains(destination) else { return values }
        let moved = source.sorted().map { values[$0] }
        var result = values.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        result.insert(contentsOf: moved, at: destination - source.filter { $0 < destination }.count)
        guard result.map(\.id) != values.map(\.id) else { return values }
        for index in result.indices { result[index].sortOrder = Double(index) }
        return result
    }
}

nonisolated struct TagItem: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var deletedAt: Date?
    var isDeleted: Bool { deletedAt != nil }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}

nonisolated enum TaskDetailsError: Error, Equatable, LocalizedError {
    case invalidDraft, recurringSubtasks, missingTask, missingSubtask, duplicateSubtask
    case subtaskLimit, tagLimit, taskTagLimit, unavailableTag, duplicateTagName, invalidTagName, missingOwner

    var errorDescription: String? {
        switch self {
        case .invalidDraft: "Vérifiez les champs de la tâche et de ses sous-tâches."
        case .recurringSubtasks: "Les sous-tâches sont disponibles pour les tâches sans répétition."
        case .missingTask: "Cette tâche n’est plus disponible."
        case .missingSubtask: "Une sous-tâche a été retirée ailleurs. Relisez la version actuelle."
        case .duplicateSubtask: "Cette sous-tâche existe déjà."
        case .subtaskLimit: "Une tâche peut contenir jusqu’à 50 sous-tâches."
        case .tagLimit: "Le catalogue peut contenir jusqu’à 200 tags actifs."
        case .taskTagLimit: "Une tâche peut avoir jusqu’à 10 tags."
        case .unavailableTag: "Un tag n’est plus disponible. Choisissez un tag actif."
        case .duplicateTagName: "Un tag actif porte déjà ce nom."
        case .invalidTagName: "Le nom d’un tag doit contenir entre 1 et 50 caractères."
        case .missingOwner: "L’identité de cet iPhone n’est pas disponible. Réessayez après l’appairage."
        }
    }
}
