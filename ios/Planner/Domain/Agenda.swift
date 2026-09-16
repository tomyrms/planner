import Foundation

/// Sections of Today (02_Design/05_Calendar_Task_UX.md): a task appears once, in the first matching section,
/// except that a late task whose deadline has passed only shows under "Échéance dépassée".
nonisolated struct TodayAgenda: Sendable {
    var commitments: [TaskItem] = []
    var todo: [TaskItem] = []
    var deadlines: [TaskItem] = []
    var toReplan: [TaskItem] = []
    var overdue: [TaskItem] = []

    init(tasks: [TaskItem], today: CivilDate, zone: TimeZone = .current) {
        var timed: [(LocalTime, TaskItem)] = []
        for task in tasks where !task.isCompleted && !task.isDeleted && !task.isRecurring {
            let planned = task.schedule?.local(in: zone)
            let due = task.deadline?.local(in: zone).date
            if let planned, planned.date == today {
                if let time = planned.time { timed.append((time, task)) } else { todo.append(task) }
            } else if let due, due == today {
                deadlines.append(task)
            } else if let due, due < today {
                overdue.append(task)
            } else if let planned, planned.date < today {
                toReplan.append(task)
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
        let minutes = commitments.compactMap(\.durationMinutes).reduce(0, +)
        let tasks = count == 1 ? "1 tâche" : "\(count) tâches"
        return minutes > 0 ? "\(tasks) · \(DurationText.format(minutes)) planifiées" : tasks
    }
}

/// Upcoming: the next 14 days grouped by date, then "Plus tard". A task sits on its planned day, else its deadline.
nonisolated struct UpcomingAgenda: Sendable {
    nonisolated struct Day: Identifiable, Sendable {
        let date: CivilDate
        var tasks: [TaskItem]
        var id: CivilDate { date }
    }

    var days: [Day] = []
    var later: [TaskItem] = []

    init(tasks: [TaskItem], today: CivilDate, zone: TimeZone = .current) {
        let horizon = today.adding(days: 14)
        var byDay: [CivilDate: [(LocalTime?, TaskItem)]] = [:]
        for task in tasks where !task.isCompleted && !task.isDeleted && !task.isRecurring {
            let planned = task.schedule?.local(in: zone)
            let anchor = planned?.date ?? task.deadline?.local(in: zone).date
            guard let anchor, anchor > today else { continue }
            if anchor <= horizon {
                byDay[anchor, default: []].append((planned?.time, task))
            } else {
                later.append(task)
            }
        }
        days = byDay.keys.sorted().map { date in
            let entries = byDay[date] ?? []
            let sorted = entries.sorted { lhs, rhs in
                switch (lhs.0, rhs.0) {
                case let (left?, right?): left < right
                case (nil, _?): true
                default: false
                }
            }
            return Day(date: date, tasks: sorted.map(\.1))
        }
    }

    var isEmpty: Bool { days.isEmpty && later.isEmpty }
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
