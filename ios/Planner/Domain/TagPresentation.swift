import Foundation

/// Display/search only. Never changes stored names, tag IDs or assignments.
nonisolated enum TagPresentation {
    static func singleLine(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func summary(_ names: [String], visibleCount: Int = 2) -> String {
        let count = min(names.count, max(0, visibleCount))
        guard count > 0 else { return names.isEmpty ? "" : "\(names.count)" }
        let text = names.prefix(count).map(singleLine).joined(separator: " · ")
        let remaining = names.count - count
        return remaining > 0 ? "\(text) +\(remaining)" : text
    }

    static func matches(_ name: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CH")) != nil
    }
}
