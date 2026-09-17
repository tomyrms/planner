import Foundation

/// A calendar date without time or zone ("2026-09-17"), as stored and sent by the backend.
nonisolated struct CivilDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses "YYYY-MM-DD" (a longer timestamp is cut to its date).
    init?(_ text: String?) {
        guard let text else { return nil }
        let parts = text.prefix(10).split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    init(_ date: Date, in timeZone: TimeZone = .current) {
        self = TimeResolver.localDate(at: date, in: timeZone)
    }

    static func today(in timeZone: TimeZone = .current) -> CivilDate {
        CivilDate(Date(), in: timeZone)
    }

    var description: String {
        "\(Self.pad(year, 4))-\(Self.pad(month, 2))-\(Self.pad(day, 2))"
    }

    /// Noon on that day in the given zone: a safe anchor for display and day arithmetic.
    func noon(in timeZone: TimeZone = .current) -> Date {
        Calendar.planner(in: timeZone).date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    func adding(days: Int) -> CivilDate {
        CivilDate(dayNumber: dayNumber + days)
    }

    func days(until other: CivilDate) -> Int {
        other.dayNumber - dayNumber
    }

    static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    fileprivate static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

/// A wall-clock time ("17:00"); the backend may add seconds ("17:00:00").
nonisolated struct LocalTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    init?(_ text: String?) {
        guard let text else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    init(_ date: Date, in timeZone: TimeZone = .current) {
        self = TimeResolver.project(date, into: timeZone).time
    }

    /// "17:00", the form the commands use.
    var description: String {
        "\(CivilDate.pad(hour, 2)):\(CivilDate.pad(minute, 2))"
    }

    static func < (lhs: LocalTime, rhs: LocalTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

/// A planned or due moment: a floating date, or a date and time in an IANA zone (04_Backend/03_Data_Model.md).
nonisolated struct TimeValue: Hashable, Sendable {
    var date: CivilDate
    var time: LocalTime?
    var timeZone: String?

    init(date: CivilDate, time: LocalTime? = nil, timeZone: String? = nil) {
        self.date = date
        self.time = time
        self.timeZone = time == nil ? nil : (timeZone ?? TimeZone.current.identifier)
    }

    /// Rebuilds a value from its three stored columns.
    init?(date: String?, time: String?, timeZone: String?) {
        guard let civil = CivilDate(date) else { return nil }
        let clock = LocalTime(time)
        self.init(date: civil, time: clock, timeZone: clock == nil ? nil : timeZone)
    }

    /// The instant of a timed value; a date alone has none.
    var instant: Date? {
        guard let time, let timeZone else { return nil }
        return TimeResolver.resolve(date: date, time: time, zone: timeZone)?.instant
    }

    /// Date and time as seen on this device: a timed value is converted from its own zone.
    func local(in zone: TimeZone = .current) -> (date: CivilDate, time: LocalTime?) {
        guard let instant else { return (date, nil) }
        let projected = TimeResolver.project(instant, into: zone)
        return (projected.date, projected.time)
    }

    /// The zone differs from the device's: worth showing next to the time.
    var isInOtherZone: Bool {
        guard let timeZone else { return false }
        return timeZone != TimeZone.current.identifier
    }

    /// `{ date, time, timeZone }` as the commands expect it.
    var payload: JSONPayload {
        [
            "date": .string(date.description),
            "time": time.map { JSONPayload.string($0.description) } ?? .null,
            "timeZone": timeZone.map { JSONPayload.string($0) } ?? .null,
        ]
    }
}

nonisolated extension Calendar {
    static func planner(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

/// Timestamps exchanged with the backend and stored by the sync engine (ISO 8601, UTC).
nonisolated enum Timestamp {
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let normalized = text.replacingOccurrences(of: " ", with: "T")
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(normalized) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(normalized)
    }

    static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
