import Foundation

/// One line of a day: a simple task, or one occurrence of a series, with its effective planned value.
nonisolated struct AgendaItem: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        /// Planned that day (schedule, or occurrence).
        case planned
        /// Only due that day.
        case deadline
        /// Several missed occurrences of a fixed series, grouped on one line.
        case missedGroup(count: Int)
    }

    let task: TaskItem
    let occurrenceKey: String?
    let kind: Kind
    /// Planned value of the occurrence (override included), or the task's own.
    let schedule: TimeValue?
    /// The occurrence was moved away from its origin date.
    let isMoved: Bool

    var id: String {
        switch kind {
        case .missedGroup: "missed:\(task.id)"
        case .deadline: "deadline:\(task.id)"
        case .planned: occurrenceKey.map { "\(task.id):\($0)" } ?? task.id
        }
    }

    var isOccurrence: Bool { occurrenceKey != nil }
    var originDate: CivilDate? { occurrenceKey.flatMap(OccurrenceKey.date(of:)) }

    static func simple(_ task: TaskItem, kind: Kind = .planned) -> AgendaItem {
        AgendaItem(task: task, occurrenceKey: nil, kind: kind, schedule: task.schedule, isMoved: false)
    }
}

/// Occurrences of a series, computed for a bounded window and merged with materialized rows (§4.3).
nonisolated enum SeriesCalculator {
    /// Open occurrences whose effective local date is in [from, through] (at most 58 days).
    static func openOccurrences(task: TaskItem, rows: [OccurrenceRow], from: CivilDate, through: CivilDate, zone: TimeZone) -> [AgendaItem] {
        guard let recurrence = task.recurrence, let anchor = task.schedule, !task.isCompleted, !task.isDeleted else { return [] }
        let byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        func item(key: String, origin: CivilDate) -> AgendaItem? {
            let row = byKey[key]
            guard (row?.status ?? OccurrenceStatus.open) == .open else { return nil }
            let effective = row?.override ?? TimeValue(date: origin, time: anchor.time, timeZone: anchor.timeZone)
            let local = effective.local(in: zone).date
            guard local >= from && local <= through else { return nil }
            return AgendaItem(task: task, occurrenceKey: key, kind: .planned, schedule: effective, isMoved: row?.override != nil)
        }
        switch recurrence {
        case .fixed(let rule):
            var items: [AgendaItem] = []
            var seen = Set<String>()
            let start = from.adding(days: -1)
            let end = min(through.adding(days: 1), start.adding(days: 59))
            for origin in rule.dates(anchor: anchor.date, from: start, through: end) {
                let key = OccurrenceKey.fixed(origin)
                seen.insert(key)
                if let value = item(key: key, origin: origin) { items.append(value) }
            }
            // Occurrences moved into the window from elsewhere.
            for row in rows where row.status == .open && row.override != nil && !seen.contains(row.key) {
                guard let origin = OccurrenceKey.date(of: row.key), rule.contains(origin, anchor: anchor.date) else { continue }
                if let value = item(key: row.key, origin: origin) { items.append(value) }
            }
            return items
        case .afterCompletion:
            let key = currentKey(anchor: anchor.date, rows: byKey)
            guard let origin = OccurrenceKey.date(of: key) else { return [] }
            return item(key: key, origin: origin).map { [$0] } ?? []
        }
    }

    /// The single open occurrence of an after-completion series: follow the successors from `anchor~0`.
    static func currentKey(anchor: CivilDate, rows: [String: OccurrenceRow]) -> String {
        var key = OccurrenceKey.afterCompletion(anchor, cycle: 0)
        var steps = 0
        while let row = rows[key], row.status != .open, let next = row.successorKey, steps < 10_000 {
            key = next
            steps += 1
        }
        return key
    }

    /// The current occurrence of an after-completion series, wherever its date is.
    static func currentOccurrence(task: TaskItem, rows: [OccurrenceRow]) -> AgendaItem? {
        guard case .afterCompletion = task.recurrence, let anchor = task.schedule, !task.isCompleted else { return nil }
        let byKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return occurrence(task: task, rows: rows, key: currentKey(anchor: anchor.date, rows: byKey))
    }

    /// One occurrence by key, whatever its state (a notification or a link points to it).
    static func occurrence(task: TaskItem, rows: [OccurrenceRow], key: String) -> AgendaItem? {
        guard let anchor = task.schedule, let origin = OccurrenceKey.date(of: key) else { return nil }
        let row = rows.first { $0.key == key }
        let effective = row?.override ?? TimeValue(date: origin, time: anchor.time, timeZone: anchor.timeZone)
        return AgendaItem(task: task, occurrenceKey: key, kind: .planned, schedule: effective, isMoved: row?.override != nil)
    }

    /// The value an occurrence has without a move: moving it back there cancels the move.
    static func naturalSchedule(task: TaskItem, key: String) -> TimeValue? {
        guard let anchor = task.schedule, let origin = OccurrenceKey.date(of: key) else { return nil }
        return TimeValue(date: origin, time: anchor.time, timeZone: anchor.timeZone)
    }

    /// Missed occurrences of a fixed series before today, grouped (§4.4).
    static func missedGroup(task: TaskItem, rows: [OccurrenceRow], today: CivilDate) -> AgendaItem? {
        guard case .fixed(let rule) = task.recurrence, let anchor = task.schedule, !task.isCompleted, !task.isDeleted else { return nil }
        let materialized = rows.compactMap { row -> FixedRule.Materialized? in
            guard let key = CivilDate(row.key), row.key.count == 10 else { return nil }
            return FixedRule.Materialized(occurrenceKey: key, status: row.status, overrideDate: row.override?.date)
        }
        let missed = rule.missed(anchor: anchor.date, before: today, materialized: materialized, ignoredBefore: task.missedIgnoredBefore)
        guard missed.count > 0, let latest = missed.latest else { return nil }
        let key = OccurrenceKey.fixed(latest)
        let row = rows.first { $0.key == key }
        let effective = row?.override ?? TimeValue(date: latest, time: anchor.time, timeZone: anchor.timeZone)
        return AgendaItem(task: task, occurrenceKey: key, kind: .missedGroup(count: missed.count), schedule: effective, isMoved: row?.override != nil)
    }

    /// The next open occurrence on or after a date (series editor, reminders).
    static func nextOccurrence(task: TaskItem, rows: [OccurrenceRow], onOrAfter date: CivilDate, zone: TimeZone) -> AgendaItem? {
        if case .afterCompletion = task.recurrence { return currentOccurrence(task: task, rows: rows) }
        return openOccurrences(task: task, rows: rows, from: date, through: date.adding(days: 56), zone: zone)
            .min { ($0.schedule?.local(in: zone).date ?? date) < ($1.schedule?.local(in: zone).date ?? date) }
    }
}

/// Sections of Today (02_Design/05_Calendar_Task_UX.md): a task appears once, in the first matching section,
/// except that a late task whose deadline has passed only shows under "Échéance dépassée".
nonisolated struct TodayAgenda: Sendable {
    var commitments: [AgendaItem] = []
    var todo: [AgendaItem] = []
    var deadlines: [AgendaItem] = []
    var toReplan: [AgendaItem] = []
    var overdue: [AgendaItem] = []

    init(tasks: [TaskItem], occurrences: [String: [OccurrenceRow]], today: CivilDate, zone: TimeZone = .current) {
        var timed: [(LocalTime, AgendaItem)] = []
        for task in tasks where !task.isCompleted && !task.isDeleted {
            if task.isRecurring {
                let rows = occurrences[task.id] ?? []
                for item in SeriesCalculator.openOccurrences(task: task, rows: rows, from: today, through: today, zone: zone) {
                    if let time = item.schedule?.local(in: zone).time { timed.append((time, item)) } else { todo.append(item) }
                }
                if let missed = SeriesCalculator.missedGroup(task: task, rows: rows, today: today) {
                    toReplan.append(missed)
                }
                if let current = SeriesCalculator.currentOccurrence(task: task, rows: rows),
                   let date = current.schedule?.local(in: zone).date, date < today {
                    toReplan.append(current)
                }
                continue
            }
            let planned = task.schedule?.local(in: zone)
            let due = task.deadline?.local(in: zone).date
            if let planned, planned.date == today {
                if let time = planned.time { timed.append((time, .simple(task))) } else { todo.append(.simple(task)) }
            } else if let due, due == today {
                deadlines.append(.simple(task, kind: .deadline))
            } else if let due, due < today {
                overdue.append(.simple(task, kind: .deadline))
            } else if let planned, planned.date < today {
                toReplan.append(.simple(task))
            }
        }
        commitments = timed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    var isEmpty: Bool {
        commitments.isEmpty && todo.isEmpty && deadlines.isEmpty && toReplan.isEmpty && overdue.isEmpty
    }

    /// "5 tâches · 1 h 45 planifiées": only known durations count.
    var summary: String? {
        let count = commitments.count + todo.count + deadlines.count
        guard count > 0 else { return nil }
        let minutes = commitments.compactMap(\.task.durationMinutes).reduce(0, +)
        let tasks = count == 1 ? "1 tâche" : "\(count) tâches"
        return minutes > 0 ? "\(tasks) · \(DurationText.format(minutes)) planifiées" : tasks
    }
}

/// One civil day: without time first, then chronological, then deadlines (Calendar agenda, Upcoming).
nonisolated struct DayAgenda: Sendable {
    var untimed: [AgendaItem] = []
    var timed: [AgendaItem] = []
    var deadlines: [AgendaItem] = []

    var isEmpty: Bool { untimed.isEmpty && timed.isEmpty && deadlines.isEmpty }
    var count: Int { untimed.count + timed.count + deadlines.count }
    var all: [AgendaItem] { untimed + timed + deadlines }

    /// Every day of [from, through] (58 days at most) that has something.
    static func days(tasks: [TaskItem], occurrences: [String: [OccurrenceRow]], from: CivilDate, through: CivilDate,
                     zone: TimeZone = .current) -> [CivilDate: DayAgenda] {
        var result: [CivilDate: DayAgenda] = [:]
        var timed: [CivilDate: [(LocalTime, AgendaItem)]] = [:]
        func inRange(_ date: CivilDate) -> Bool { date >= from && date <= through }
        for task in tasks where !task.isCompleted && !task.isDeleted {
            if task.isRecurring {
                for item in SeriesCalculator.openOccurrences(task: task, rows: occurrences[task.id] ?? [], from: from, through: through, zone: zone) {
                    guard let local = item.schedule?.local(in: zone) else { continue }
                    if let time = local.time { timed[local.date, default: []].append((time, item)) } else { result[local.date, default: DayAgenda()].untimed.append(item) }
                }
                continue
            }
            if let planned = task.schedule?.local(in: zone), inRange(planned.date) {
                if let time = planned.time { timed[planned.date, default: []].append((time, .simple(task))) } else { result[planned.date, default: DayAgenda()].untimed.append(.simple(task)) }
            }
            if let due = task.deadline?.local(in: zone).date, inRange(due), task.schedule?.local(in: zone).date != due {
                result[due, default: DayAgenda()].deadlines.append(.simple(task, kind: .deadline))
            }
        }
        for (date, entries) in timed {
            result[date, default: DayAgenda()].timed = entries.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return result
    }
}

/// Upcoming: the next 14 days grouped by date, then "Plus tard" (simple tasks only; series show their days).
nonisolated struct UpcomingAgenda: Sendable {
    nonisolated struct Day: Identifiable, Sendable {
        let date: CivilDate
        let agenda: DayAgenda
        var id: CivilDate { date }
    }

    var days: [Day] = []
    var later: [AgendaItem] = []

    init(tasks: [TaskItem], occurrences: [String: [OccurrenceRow]], today: CivilDate, zone: TimeZone = .current) {
        let from = today.adding(days: 1)
        let through = today.adding(days: 14)
        let map = DayAgenda.days(tasks: tasks, occurrences: occurrences, from: from, through: through, zone: zone)
        days = map.keys.sorted().compactMap { date in map[date].map { Day(date: date, agenda: $0) } }
        for task in tasks where !task.isCompleted && !task.isDeleted && !task.isRecurring {
            let anchor = task.schedule?.local(in: zone).date ?? task.deadline?.local(in: zone).date
            if let anchor, anchor > through { later.append(.simple(task)) }
        }
        later.sort { ($0.task.schedule?.date ?? $0.task.deadline?.date ?? through) < ($1.task.schedule?.date ?? $1.task.deadline?.date ?? through) }
    }

    var isEmpty: Bool { days.isEmpty && later.isEmpty }
}

/// The weeks shown by the month view: Monday first, 5 or 6 rows of 7 days (at most 42 days).
nonisolated enum MonthGrid {
    static func days(for month: CivilDate) -> [CivilDate] {
        let first = month.firstOfMonth
        let lead = first.isoWeekday - 1
        let length = CivilDate.monthLength(year: first.year, month: first.month)
        let cells = (lead + length + 6) / 7 * 7
        let start = first.adding(days: -lead)
        return (0..<cells).map { start.adding(days: $0) }
    }
}

nonisolated extension CivilDate {
    var firstOfMonth: CivilDate { CivilDate(year: year, month: month, day: 1) }

    var weekday: Weekday { Weekday.allCases[isoWeekday - 1] }
}

nonisolated enum DurationText {
    /// "45 min", "1 h", "1 h 30".
    static func format(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) h"
        default: return "\(hours) h \(rest < 10 ? "0" : "")\(rest)"
        }
    }
}

/// Parses the link printed by `npm run admin -- pair`: `planner://pair?api=<https URL>&secret=<secret>`.
nonisolated struct PairingLink: Sendable, Equatable {
    let apiURL: URL
    let secret: String

    init?(link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme == "planner", components.host == "pair" else { return nil }
        let items = components.queryItems ?? []
        guard let api = items.first(where: { $0.name == "api" })?.value,
              let secret = items.first(where: { $0.name == "secret" })?.value else { return nil }
        self.init(server: api, secret: secret)
    }

    init?(server: String, secret: String) {
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        // App Transport Security stays intact: only HTTPS servers (04_Backend/06_Security_Privacy.md).
        guard let url = URL(string: address), url.scheme?.lowercased() == "https", url.host() != nil, !key.isEmpty else { return nil }
        self.apiURL = url
        self.secret = key
    }
}
