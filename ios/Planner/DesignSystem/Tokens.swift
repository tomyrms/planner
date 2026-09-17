import SwiftUI

/// Spacing scale for our own compositions (02_Design/06_Components_Tokens.md); native insets are left alone.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum Radius {
    static let medium: CGFloat = 12
}

/// Comfort target of the project for common actions.
enum TouchTarget {
    static let comfort: CGFloat = 44
}

/// Dates as the screens say them: "aujourd’hui", "demain", "vendredi", "18 sept.".
nonisolated enum DateText {
    static func day(_ date: CivilDate, today: CivilDate) -> String {
        switch today.days(until: date) {
        case 0: return "aujourd’hui"
        case 1: return "demain"
        case -1: return "hier"
        case 2...6: return date.noon().formatted(.dateTime.weekday(.wide))
        default:
            let anchor = date.noon()
            return date.year == today.year
                ? anchor.formatted(.dateTime.day().month(.abbreviated))
                : anchor.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }

    /// Title of a day section: "Jeudi 17 septembre".
    static func heading(_ date: CivilDate) -> String {
        date.noon().formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst
    }

    /// Planned or due moment on this iPhone: "demain 17:00", with the zone when it differs.
    static func moment(_ value: TimeValue, today: CivilDate, showDay: Bool = true) -> String {
        let local = value.local()
        var parts: [String] = []
        if showDay { parts.append(day(local.date, today: today)) }
        if let time = local.time { parts.append(time.description) }
        var text = parts.joined(separator: " ")
        if value.isInOtherZone, let zone = value.timeZone {
            text += " (\(zone))"
        }
        return text
    }
}

nonisolated extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
