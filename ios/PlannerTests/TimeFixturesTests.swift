import Foundation
import Testing
@testable import Planner

/// The shared literal fixtures of `planner/fixtures/time` (ADR-027): the same inputs and expected results
/// as the TypeScript tests. Nothing here computes its own expectation.
struct TimeFixturesTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let taskId = "11111111-1111-4111-8111-111111111111"

    static func cases(_ file: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: root.appending(path: "fixtures/time/\(file)"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["cases"] as? [[String: Any]])
    }

    static func ids(_ file: String) -> [String] {
        ((try? cases(file)) ?? []).compactMap { $0["id"] as? String }
    }

    static func fixture(_ file: String, id: String) throws -> [String: Any] {
        try #require(try cases(file).first { $0["id"] as? String == id })
    }

    static let v1Ids = ids("v1.json")

    @Test func fixturesAreLoaded() {
        #expect(Self.v1Ids.count >= 48)
    }

    @Test(arguments: TimeFixturesTests.v1Ids)
    func sharedCase(_ id: String) throws {
        let fixture = try Self.fixture("v1.json", id: id)
        let operation = try #require(fixture["operation"] as? String)
        let input = fixture["input"]
        let expected = fixture["expected"]
        let actual = try Self.run(operation, input)
        #expect(Self.canonical(actual) == Self.canonical(expected), "\(id): \(String(describing: actual)) ≠ \(String(describing: expected))")
    }

    // MARK: - Operations

    static func run(_ operation: String, _ input: Any?) throws -> Any? {
        let object = input as? [String: Any] ?? [:]
        switch operation {
        case "resolve":
            guard let value = timeValue(input) else { return NSNull() }
            guard let time = value.time, let zone = value.timeZone else { return ["kind": "date", "date": value.date.description] }
            let resolved = try #require(TimeResolver.resolve(date: value.date, time: time, zone: zone))
            return [
                "kind": "timed", "date": value.date.description, "time": time.description, "timeZone": zone,
                "instant": InstantText.format(resolved.instant), "effectiveDate": resolved.effectiveDate.description,
                "effectiveTime": resolved.effectiveTime.description, "adjustment": resolved.adjustment.rawValue,
            ]
        case "project":
            let value = try #require(timeValue(object["value"]))
            let zoneId = try #require(object["displayTimeZone"] as? String)
            guard value.time != nil else { return ["date": value.date.description, "time": NSNull(), "timeZone": NSNull()] }
            let local = value.local(in: try #require(TimeZone(identifier: zoneId)))
            return ["date": local.date.description, "time": local.time?.description ?? "", "timeZone": zoneId]
        case "overdue":
            let zone = try #require(TimeZone(identifier: object["deviceTimeZone"] as? String ?? ""))
            let now = try #require(InstantText.parse(object["referenceInstant"] as? String ?? ""))
            return TimeResolver.isOverdue(timeValue(object["value"]), now: now, zone: zone)
        case "relative":
            let zone = try #require(TimeZone(identifier: object["timeZone"] as? String ?? ""))
            let now = try #require(InstantText.parse(object["referenceInstant"] as? String ?? ""))
            return TimeResolver.localDate(at: now, in: zone).adding(days: object["days"] as? Int ?? 0).description
        case "fixedKeys":
            let rule = try fixedRule(object["rule"])
            let anchor = try date(object["anchor"])
            let from = try date(object["from"])
            let through = try date(object["through"])
            let keys = rule.dates(anchor: anchor, from: from, through: through).map(\.description)
            _ = OccurrenceKey.id(taskId: taskId, key: anchor.description)
            return keys
        case "missed":
            let rule = try fixedRule(object["rule"])
            let rows = (object["materialized"] as? [[String: Any]] ?? []).map { row in
                FixedRule.Materialized(
                    occurrenceKey: CivilDate(row["occurrenceKey"] as? String)!,
                    status: OccurrenceStatus(rawValue: row["status"] as? String ?? "") ?? .open,
                    overrideDate: CivilDate(row["overrideDate"] as? String)
                )
            }
            let result = rule.missed(
                anchor: try date(object["anchor"]), before: try date(object["beforeDate"]),
                materialized: rows, ignoredBefore: CivilDate(object["ignoredBefore"] as? String)
            )
            let latest: Any = result.latest.map { $0.description } ?? NSNull()
            return ["count": result.count, "latestOccurrenceKey": latest]
        case "fixedMember":
            let rule = try fixedRule(object["rule"])
            let anchor = try date(object["anchor"])
            return (object["dates"] as? [String] ?? []).map { rule.contains(CivilDate($0)!, anchor: anchor) } as [Bool]
        case "nextAfterFromDate":
            return try afterRule(object["rule"]).nextDate(after: try date(object["completedLocalDate"])).description
        case "nextAfter":
            let zone = try #require(TimeZone(identifier: object["deviceTimeZone"] as? String ?? ""))
            let now = try #require(InstantText.parse(object["referenceInstant"] as? String ?? ""))
            return try afterRule(object["rule"]).nextDate(after: TimeResolver.localDate(at: now, in: zone)).description
        case "occurrenceId":
            return OccurrenceKey.id(taskId: object["taskId"] as? String ?? "", key: object["occurrenceKey"] as? String ?? "")
        case "closeAfter":
            return try closeAfter(object)
        case "reopenAfter":
            var state = try #require(object["state"] as? [String: Any])
            if state["status"] as? String == "open" { return ["outcome": "duplicate", "state": state] }
            if object["successorMaterialized"] as? Bool == true {
                return ["outcome": "rejected", "code": "SUCCESSOR_ALREADY_CHANGED", "state": state]
            }
            state["status"] = "open"
            state["completedAt"] = NSNull()
            state["successorOccurrenceKey"] = NSNull()
            return ["outcome": "applied", "state": state]
        case "reminderTrigger":
            let reminder = try #require(object["reminder"] as? [String: Any])
            let absolute = reminder["absolute"] as? [String: Any]
            let rule = try #require(ReminderRule(
                kind: reminder["kind"] as? String, offsetMinutes: reminder["offsetMinutes"] as? Int,
                localTime: reminder["localTime"] as? String, absoluteDate: absolute?["date"] as? String,
                absoluteTime: absolute?["time"] as? String, absoluteZone: absolute?["timeZone"] as? String
            ))
            let zone = try #require(TimeZone(identifier: object["deviceTimeZone"] as? String ?? ""))
            switch ReminderMath.trigger(rule, schedule: timeValue(object["schedule"]), deadline: timeValue(object["deadline"]), deviceZone: zone) {
            case .active(let date): return ["state": "active", "triggerAt": InstantText.format(date)]
            case .baseMissing: return ["state": "inactive_base_missing", "triggerAt": NSNull()]
            }
        default:
            Issue.record("Unknown operation \(operation)")
            return nil
        }
    }

    /// The pure transition the server applies; the app only previews it.
    static func closeAfter(_ object: [String: Any]) throws -> Any {
        var state = try #require(object["state"] as? [String: Any])
        guard state["status"] as? String == "open" else { return ["outcome": "duplicate", "state": state] }
        let zone = try #require(TimeZone(identifier: object["deviceTimeZone"] as? String ?? ""))
        let instant = try #require(object["referenceInstant"] as? String)
        let now = try #require(InstantText.parse(instant))
        let key = try #require(state["occurrenceKey"] as? String)
        let next = try afterRule(object["rule"]).nextDate(after: TimeResolver.localDate(at: now, in: zone))
        let complete = object["action"] as? String == "complete"
        state["status"] = complete ? "completed" : "skipped"
        state["completedAt"] = complete ? InstantText.format(now) : NSNull()
        state["successorOccurrenceKey"] = OccurrenceKey.next(after: key, date: next) ?? NSNull()
        return ["outcome": "applied", "state": state]
    }

    // MARK: - Decoding helpers

    static func timeValue(_ any: Any?) -> TimeValue? {
        guard let object = any as? [String: Any] else { return nil }
        return TimeValue(date: object["date"] as? String, time: object["time"] as? String, timeZone: object["timeZone"] as? String)
    }

    static func date(_ any: Any?) throws -> CivilDate {
        try #require(CivilDate(any as? String))
    }

    static func rule(_ any: Any?) throws -> RecurrenceRule {
        let object = try #require(any as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(RecurrenceRule(json: String(decoding: data, as: UTF8.self)))
    }

    static func fixedRule(_ any: Any?) throws -> FixedRule {
        guard case .fixed(let rule) = try rule(any) else { throw CocoaError(.coderInvalidValue) }
        return rule
    }

    static func afterRule(_ any: Any?) throws -> AfterCompletionRule {
        guard case .afterCompletion(let rule) = try rule(any) else { throw CocoaError(.coderInvalidValue) }
        return rule
    }

    /// Order-independent JSON text, so that dictionaries compare by content.
    static func canonical(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }
}

/// `reminder-plans-v1.json`: windows, capacity and proofs of scheduling.
struct ReminderPlanFixturesTests {
    static let planIds = TimeFixturesTests.ids("reminder-plans-v1.json")

    @Test(arguments: ReminderPlanFixturesTests.planIds)
    func plan(_ id: String) throws {
        let fixture = try TimeFixturesTests.fixture("reminder-plans-v1.json", id: id)
        let now = try #require(InstantText.parse(fixture["referenceInstant"] as? String ?? ""))
        let zone = try #require(TimeZone(identifier: fixture["deviceTimeZone"] as? String ?? ""))
        let trigger = try #require(InstantText.parse(fixture["triggerAt"] as? String ?? ""))
        let count = fixture["candidateCount"] as? Int ?? 0
        let ids = (0..<count).map { index in
            let suffix = String(index)
            return ReminderMath.notificationId(
                reminderId: "11111111-1111-4111-8111-" + String(repeating: "0", count: 12 - suffix.count) + suffix,
                occurrenceKey: nil
            )
        }
        let candidates = ids.map { ReminderMath.Candidate(notificationId: $0, trigger: .active(trigger), eligible: true) }
        let pending = fixture["systemPending"] as? Bool == true ? ids.map { ReminderMath.Request(notificationId: $0, triggerAt: trigger) } : []
        var acceptances: [String: (triggerAt: Date, acceptedAt: Date)] = [:]
        if let accepted = (fixture["acceptedAt"] as? String).flatMap(InstantText.parse) {
            for id in ids { acceptances[id] = (trigger, accepted) }
        }
        let plan = ReminderMath.plan(
            now: now, zone: zone, authorized: fixture["notificationsAuthorized"] as? Bool ?? false,
            candidates: candidates, systemPending: pending, acceptances: acceptances
        )
        let expected = try #require(fixture["expected"] as? [String: Any])
        #expect(plan.desired.count == expected["desiredCount"] as? Int)
        #expect(plan.addOrReplace.count == expected["addOrReplaceCount"] as? Int)
        var counts: [String: Int] = [:]
        for state in plan.states.values { counts[state.rawValue, default: 0] += 1 }
        #expect(counts == (expected["stateCounts"] as? [String: Int] ?? [:]))
    }
}

/// Search normalization shared with the backend (`normalizeSearchText`).
struct SearchTextTests {
    @Test func accentsCaseAndCSharp() {
        #expect(SearchText.normalize(["Réviser le Devoir C#", nil, "Cours"]) == "reviser le devoir c# cours")
        #expect(SearchText.normalize(["  Prise   de   RDV — garage!  "]) == "prise de rdv garage")
        #expect(SearchText.normalize(["e-mail v2.1 + notes"]) == "e-mail v2.1 + notes")
    }
}
