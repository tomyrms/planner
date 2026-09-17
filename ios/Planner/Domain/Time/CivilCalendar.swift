import Foundation

/// Proleptic Gregorian arithmetic without Calendar: deterministic, and the same rules as the backend
/// (`planner/src/modules/time`, fixtures `planner/fixtures/time/v1.json`).
nonisolated extension CivilDate {
    /// Days since 1970-01-01 (H. Hinnant's algorithm).
    var dayNumber: Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    init(dayNumber: Int) {
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        self.init(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    /// ISO weekday: 1 = Monday … 7 = Sunday.
    var isoWeekday: Int {
        let index = (dayNumber + 3) % 7
        return (index < 0 ? index + 7 : index) + 1
    }

    static func isLeap(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    static func monthLength(year: Int, month: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Adds months, constrained to the last day of the target month (31 January + 1 month = 28/29 February).
    func adding(months: Int) -> CivilDate {
        let index = year * 12 + (month - 1) + months
        let newYear = index >= 0 ? index / 12 : (index - 11) / 12
        let newMonth = index - newYear * 12 + 1
        return CivilDate(year: newYear, month: newMonth, day: min(day, Self.monthLength(year: newYear, month: newMonth)))
    }

    var isValid: Bool {
        (1...9999).contains(year) && (1...12).contains(month) && (1...Self.monthLength(year: year, month: month)).contains(day)
    }
}

/// Wall-clock seconds of a civil date and time, as if it were UTC.
nonisolated enum WallClock {
    static func seconds(_ date: CivilDate, _ time: LocalTime, second: Int = 0) -> Int {
        date.dayNumber * 86_400 + time.hour * 3600 + time.minute * 60 + second
    }

    static func split(_ seconds: Int) -> (date: CivilDate, time: LocalTime, second: Int) {
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let rest = seconds - days * 86_400
        return (CivilDate(dayNumber: days), LocalTime(hour: rest / 3600, minute: rest % 3600 / 60), rest % 60)
    }
}

/// How a wall-clock time became an instant (04_Backend/03_Data_Model.md, ADR-027).
nonisolated enum TimeAdjustment: String, Sendable {
    case exact
    /// The time does not exist (spring gap): the first valid minute after it.
    case gapForward = "gap_forward"
    /// The time exists twice (autumn fold): its first instant.
    case foldFirst = "fold_first"
}

nonisolated struct ResolvedTime: Equatable, Sendable {
    let instant: Date
    let effectiveDate: CivilDate
    let effectiveTime: LocalTime
    let adjustment: TimeAdjustment
}

nonisolated enum TimeResolver {
    /// Wall-clock time in an IANA zone → instant. A missing time advances minute by minute; a repeated one
    /// takes its first instant. Nil for an unknown zone.
    static func resolve(date: CivilDate, time: LocalTime, zone identifier: String) -> ResolvedTime? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        var wall = WallClock.seconds(date, time)
        var moved = false
        for _ in 0...2880 {
            let candidates = instants(forWall: wall, in: zone)
            if let first = candidates.first {
                let parts = WallClock.split(wall)
                let adjustment: TimeAdjustment = moved ? .gapForward : candidates.count > 1 ? .foldFirst : .exact
                return ResolvedTime(instant: Date(timeIntervalSince1970: TimeInterval(first)),
                                    effectiveDate: parts.date, effectiveTime: parts.time, adjustment: adjustment)
            }
            moved = true
            wall += 60
        }
        return nil
    }

    /// Instant of a wall-clock second, for window bounds (a missing second moves forward too).
    static func instant(wallSeconds: Int, zone: TimeZone) -> Date {
        var wall = wallSeconds
        for _ in 0...172_800 {
            if let first = instants(forWall: wall, in: zone).first {
                return Date(timeIntervalSince1970: TimeInterval(first))
            }
            wall += 1
        }
        return Date(timeIntervalSince1970: TimeInterval(wallSeconds))
    }

    /// Every instant t with t + offset(t) = wall, earliest first.
    static func instants(forWall wall: Int, in zone: TimeZone) -> [Int] {
        var offsets = Set<Int>()
        for probe in [wall - 86_400, wall, wall + 86_400] {
            offsets.insert(zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(probe))))
        }
        // Offsets just around the wall time catch transitions closer than a day.
        for probe in stride(from: wall - 43_200, through: wall + 43_200, by: 1800) {
            offsets.insert(zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(probe))))
        }
        return offsets
            .map { wall - $0 }
            .filter { zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval($0))) == wall - $0 }
            .sorted()
    }

    /// Instant → civil date and time in a zone (seconds dropped).
    static func project(_ instant: Date, into zone: TimeZone) -> (date: CivilDate, time: LocalTime) {
        let seconds = Int(instant.timeIntervalSince1970.rounded(.down))
        let parts = WallClock.split(seconds + zone.secondsFromGMT(for: instant))
        return (parts.date, parts.time)
    }

    static func localDate(at instant: Date, in zone: TimeZone) -> CivilDate {
        project(instant, into: zone).date
    }

    /// Date-only values are due at the end of their civil day on this device; timed ones at their instant.
    static func isOverdue(_ value: TimeValue?, now: Date, zone: TimeZone) -> Bool {
        guard let value else { return false }
        if value.time == nil { return localDate(at: now, in: zone) > value.date }
        guard let instant = value.instant else { return false }
        return now > instant
    }
}

/// ISO 8601 instants as the backend and the fixtures write them ("2026-03-29T01:00:00Z").
nonisolated enum InstantText {
    static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    static func parse(_ text: String) -> Date? {
        Timestamp.parse(text)
    }
}
