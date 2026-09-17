import CryptoKit
import Foundation

nonisolated enum Weekday: String, CaseIterable, Hashable, Sendable {
    case monday = "MO", tuesday = "TU", wednesday = "WE", thursday = "TH", friday = "FR", saturday = "SA", sunday = "SU"

    /// 1 = Monday … 7 = Sunday.
    var isoIndex: Int { Self.allCases.firstIndex(of: self)! + 1 }

    var shortLabel: String {
        ["lun.", "mar.", "mer.", "jeu.", "ven.", "sam.", "dim."][isoIndex - 1]
    }

    var label: String {
        ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"][isoIndex - 1]
    }
}

/// Fixed series (04_Backend/03_Data_Model.md §4): not a full RRULE.
nonisolated struct FixedRule: Hashable, Sendable {
    nonisolated enum Frequency: Hashable, Sendable {
        case daily
        case weekly([Weekday])
        case monthlyDay(Int)
        case monthlyLast
    }

    var frequency: Frequency
    var interval: Int
    var until: CivilDate?
    var count: Int?

    // MARK: Membership and counting (ported from recurrence.ts)

    private func rawCount(anchor: CivilDate, through: CivilDate) -> Int {
        guard through >= anchor else { return 0 }
        switch frequency {
        case .daily:
            return anchor.days(until: through) / interval + 1
        case .weekly(let days):
            let weekStart = anchor.adding(days: -(anchor.isoWeekday - 1))
            var total = 0
            for weekday in days {
                var first = weekStart.adding(days: weekday.isoIndex - 1)
                if first < anchor { first = first.adding(days: 7 * interval) }
                let distance = first.days(until: through)
                if distance >= 0 { total += distance / (7 * interval) + 1 }
            }
            return total
        case .monthlyDay, .monthlyLast:
            let monthDelta = (through.year - anchor.year) * 12 + through.month - anchor.month
            let lastIndex = monthDelta / interval
            func candidateDay(_ index: Int) -> Int? {
                let monthIndex = anchor.year * 12 + anchor.month - 1 + index * interval
                let length = CivilDate.monthLength(year: monthIndex / 12, month: monthIndex % 12 + 1)
                if case .monthlyDay(let day) = frequency { return day <= length ? day : nil }
                return length
            }
            let period = 4800 / Self.gcd(4800, interval)
            let n = lastIndex + 1
            let remainder = n % period
            var validPerPeriod = 0
            var remainderCount = 0
            for index in 0..<min(n, period) where candidateDay(index) != nil {
                validPerPeriod += 1
                if index < remainder { remainderCount += 1 }
            }
            var total = n < period ? validPerPeriod : (n / period) * validPerPeriod + remainderCount
            if let initial = candidateDay(0), initial < anchor.day { total -= 1 }
            if let last = candidateDay(lastIndex), lastIndex * interval == monthDelta, last > through.day { total -= 1 }
            return max(0, total)
        }
    }

    func count(anchor: CivilDate, through: CivilDate) -> Int {
        let end = until.map { $0 < through ? $0 : through } ?? through
        return min(rawCount(anchor: anchor, through: end), count ?? Int.max)
    }

    func contains(_ date: CivilDate, anchor: CivilDate) -> Bool {
        count(anchor: anchor, through: date) > count(anchor: anchor, through: date.adding(days: -1))
    }

    /// Origin dates produced in a window (both bounds included, 60 days at most).
    func dates(anchor: CivilDate, from: CivilDate, through: CivilDate) -> [CivilDate] {
        let days = from.days(until: through) + 1
        guard days >= 1 else { return [] }
        return (0..<min(days, 60)).map { from.adding(days: $0) }.filter { contains($0, anchor: anchor) }
    }

    /// The first origin date on or after `date`, searching a bounded horizon.
    func nextDate(anchor: CivilDate, onOrAfter date: CivilDate, horizonDays: Int = 800) -> CivilDate? {
        var day = max(date, anchor)
        for _ in 0..<horizonDays {
            if let until, day > until { return nil }
            if contains(day, anchor: anchor) { return day }
            day = day.adding(days: 1)
        }
        return nil
    }

    private func keyAtRank(anchor: CivilDate, through: CivilDate, rank: Int) -> CivilDate {
        var low = 0
        var high = anchor.days(until: through)
        while low < high {
            let middle = (low + high) / 2
            if count(anchor: anchor, through: anchor.adding(days: middle)) >= rank { high = middle } else { low = middle + 1 }
        }
        return anchor.adding(days: low)
    }

    nonisolated struct Materialized: Hashable, Sendable {
        let occurrenceKey: CivilDate
        let status: OccurrenceStatus
        let overrideDate: CivilDate?
    }

    /// One summary of missed occurrences strictly before `beforeDate`, without building the history.
    func missed(anchor: CivilDate, before beforeDate: CivilDate, materialized: [Materialized] = [], ignoredBefore: CivilDate? = nil) -> (count: Int, latest: CivilDate?) {
        let through = beforeDate.adding(days: -1)
        let upper = count(anchor: anchor, through: through)
        let lower = ignoredBefore.map { count(anchor: anchor, through: $0.adding(days: -1)) } ?? 0
        let total = max(0, upper - lower)
        var excluded = Set<CivilDate>()
        var extras: [CivilDate] = []
        for row in materialized {
            if let ignoredBefore, row.occurrenceKey < ignoredBefore { continue }
            let effective = row.overrideDate ?? row.occurrenceKey
            let inBase = row.occurrenceKey < beforeDate && contains(row.occurrenceKey, anchor: anchor)
            let isMissed = row.status == .open && effective < beforeDate
            if inBase && !isMissed { excluded.insert(row.occurrenceKey) }
            if !inBase && isMissed { extras.append(row.occurrenceKey) }
        }
        var rank = upper
        var latest: CivilDate?
        while rank > lower {
            let key = keyAtRank(anchor: anchor, through: through, rank: rank)
            if !excluded.contains(key) {
                latest = key
                break
            }
            rank -= 1
        }
        for key in extras where latest.map({ key > $0 }) ?? true { latest = key }
        return (total - excluded.count + extras.count, latest)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }
}

nonisolated struct AfterCompletionRule: Hashable, Sendable {
    nonisolated enum Unit: String, Hashable, Sendable {
        case day, week, month
    }

    var unit: Unit
    var interval: Int

    /// Next planned date from the civil date of the action on the device.
    func nextDate(after completedLocalDate: CivilDate) -> CivilDate {
        switch unit {
        case .day: completedLocalDate.adding(days: interval)
        case .week: completedLocalDate.adding(days: 7 * interval)
        case .month: completedLocalDate.adding(months: interval)
        }
    }
}

nonisolated enum RecurrenceRule: Hashable, Sendable {
    case fixed(FixedRule)
    case afterCompletion(AfterCompletionRule)

    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }

    /// Parses the `recurrence` column (JSON text, `v: 1`).
    init?(json: String?) {
        guard let json, let value = try? JSONPayload.decode(json), case .object(let object) = value else { return nil }
        self.init(object: object)
    }

    init?(object: [String: JSONPayload]) {
        func int(_ key: String) -> Int? {
            if case .int(let value) = object[key] { return value }
            if case .double(let value) = object[key] { return Int(value) }
            return nil
        }
        func string(_ key: String) -> String? {
            if case .string(let value) = object[key] { return value }
            return nil
        }
        guard int("v") == 1, let interval = int("interval"), interval >= 1 else { return nil }
        switch string("mode") {
        case "after_completion":
            guard let unit = string("unit").flatMap(AfterCompletionRule.Unit.init(rawValue:)) else { return nil }
            self = .afterCompletion(AfterCompletionRule(unit: unit, interval: interval))
        case "fixed":
            let frequency: FixedRule.Frequency
            switch string("freq") {
            case "daily":
                frequency = .daily
            case "weekly":
                guard case .array(let items) = object["byWeekday"] else { return nil }
                let days = items.compactMap { item -> Weekday? in
                    if case .string(let code) = item { return Weekday(rawValue: code) }
                    return nil
                }
                guard !days.isEmpty else { return nil }
                frequency = .weekly(days)
            case "monthly":
                if case .bool(true) = object["lastDayOfMonth"] {
                    frequency = .monthlyLast
                } else if let day = int("byMonthDay") {
                    frequency = .monthlyDay(day)
                } else {
                    return nil
                }
            default:
                return nil
            }
            self = .fixed(FixedRule(frequency: frequency, interval: interval, until: CivilDate(string("until")), count: int("count")))
        default:
            return nil
        }
    }

    /// The JSON the commands send.
    var payload: JSONPayload {
        switch self {
        case .afterCompletion(let rule):
            return ["v": 1, "mode": "after_completion", "unit": .string(rule.unit.rawValue), "interval": .int(rule.interval)]
        case .fixed(let rule):
            var object: [String: JSONPayload] = ["v": 1, "mode": "fixed", "interval": .int(rule.interval)]
            switch rule.frequency {
            case .daily:
                object["freq"] = "daily"
            case .weekly(let days):
                object["freq"] = "weekly"
                object["byWeekday"] = .array(Weekday.allCases.filter(days.contains).map { .string($0.rawValue) })
            case .monthlyDay(let day):
                object["freq"] = "monthly"
                object["byMonthDay"] = .int(day)
            case .monthlyLast:
                object["freq"] = "monthly"
                object["lastDayOfMonth"] = true
            }
            if let until = rule.until { object["until"] = .string(until.description) }
            if let count = rule.count { object["count"] = .int(count) }
            return .object(object)
        }
    }

    /// Readable summary (02_Design/05_Calendar_Task_UX.md): "Chaque jeudi", "90 jours après la dernière fois".
    var summary: String {
        switch self {
        case .afterCompletion(let rule):
            let unit = switch rule.unit {
            case .day: rule.interval == 1 ? "jour" : "jours"
            case .week: rule.interval == 1 ? "semaine" : "semaines"
            case .month: "mois"
            }
            return "\(rule.interval) \(unit) après la dernière fois"
        case .fixed(let rule):
            var text: String
            switch rule.frequency {
            case .daily:
                text = rule.interval == 1 ? "Chaque jour" : "Tous les \(rule.interval) jours"
            case .weekly(let days):
                let names = Weekday.allCases.filter(days.contains)
                let list = names.count == 7 ? "jour" : names.map(\.label).joined(separator: ", ")
                text = rule.interval == 1 ? "Chaque \(list)" : "Toutes les \(rule.interval) semaines : \(list)"
            case .monthlyDay(let day):
                text = rule.interval == 1 ? "Chaque mois, le \(day)" : "Tous les \(rule.interval) mois, le \(day)"
            case .monthlyLast:
                text = rule.interval == 1 ? "Chaque mois, le dernier jour" : "Tous les \(rule.interval) mois, le dernier jour"
            }
            if let until = rule.until { text += ", jusqu’au " + until.noon().formatted(.dateTime.day().month(.abbreviated).year()) }
            if let count = rule.count { text += ", \(count) fois" }
            return text
        }
    }
}

nonisolated enum OccurrenceStatus: String, Hashable, Sendable {
    case open, completed, skipped
}

/// Occurrence keys and identities (ADR-027).
nonisolated enum OccurrenceKey {
    static let namespace = UUID(uuidString: "6fcb5ad1-40ec-5ca9-bfab-62083e61c443")!

    static func fixed(_ date: CivilDate) -> String {
        date.description
    }

    static func afterCompletion(_ date: CivilDate, cycle: Int) -> String {
        "\(date.description)~\(cycle)"
    }

    /// Date part of a key ("2026-09-17~3" → 2026-09-17).
    static func date(of key: String) -> CivilDate? {
        CivilDate(String(key.split(separator: "~").first ?? ""))
    }

    static func cycle(of key: String) -> Int? {
        let parts = key.split(separator: "~")
        return parts.count == 2 ? Int(parts[1]) : nil
    }

    static func next(after key: String, date: CivilDate) -> String? {
        cycle(of: key).map { afterCompletion(date, cycle: $0 + 1) }
    }

    /// UUIDv5(namespace, lowercase task UUID + ":" + key).
    static func id(taskId: String, key: String) -> String {
        uuidV5(namespace: namespace, name: "\(taskId.lowercased()):\(key)").uuidString.lowercased()
    }

    static func uuidV5(namespace: UUID, name: String) -> UUID {
        var data = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        data.append(Data(name.utf8))
        var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
