import Foundation
import Testing
@testable import Planner

/// Today, Upcoming and Calendar built from tasks and materialized occurrences (02_Design/05_Calendar_Task_UX.md).
struct AgendaTests {
    /// Thursday 17 September 2026.
    private let today = CivilDate(year: 2026, month: 9, day: 17)
    private let zone = TimeZone(identifier: "Europe/Paris")!

    private func task(
        _ id: String = "t",
        schedule: TimeValue? = nil,
        deadline: TimeValue? = nil,
        recurrence: RecurrenceRule? = nil
    ) -> TaskItem {
        TaskItem(
            id: id, projectId: nil, title: id, notes: nil, priority: .unset, isCompleted: false, completedAt: nil,
            schedule: schedule, durationMinutes: nil, deadline: deadline, recurrence: recurrence,
            missedIgnoredBefore: nil, deletedAt: nil, revision: 1, createdAt: nil
        )
    }

    private func day(_ value: Int, month: Int = 9) -> CivilDate {
        CivilDate(year: 2026, month: month, day: value)
    }

    private var daily: RecurrenceRule {
        .fixed(FixedRule(frequency: .daily, interval: 1, until: nil, count: nil))
    }

    @Test func monthGridStartsOnMondayAndCoversTheMonth() {
        let days = MonthGrid.days(for: today)
        #expect(days.first == day(31, month: 8))
        #expect(days.first?.isoWeekday == 1)
        #expect(days.count == 35)
        #expect(days.contains(day(30)))
        #expect(days.last == day(4, month: 10))
    }

    @Test func dailySeriesShowsTodayAndGroupsMissedOccurrences() {
        let series = task(schedule: TimeValue(date: day(10)), recurrence: daily)
        let agenda = TodayAgenda(tasks: [series], occurrences: [:], today: today, zone: zone)
        #expect(agenda.todo.map(\.occurrenceKey) == ["2026-09-17"])
        #expect(agenda.toReplan.count == 1)
        #expect(agenda.toReplan.first?.kind == .missedGroup(count: 7))
        #expect(agenda.toReplan.first?.occurrenceKey == "2026-09-16")
    }

    @Test func closedOccurrencesLeaveTodayAndTheMissedGroup() {
        let series = task(schedule: TimeValue(date: day(15)), recurrence: daily)
        let rows = [
            OccurrenceRow(taskId: "t", key: "2026-09-17", status: .completed, completedAt: nil, override: nil, successorKey: nil),
            OccurrenceRow(taskId: "t", key: "2026-09-16", status: .skipped, completedAt: nil, override: nil, successorKey: nil),
        ]
        let agenda = TodayAgenda(tasks: [series], occurrences: ["t": rows], today: today, zone: zone)
        #expect(agenda.todo.isEmpty)
        #expect(agenda.toReplan.first?.kind == .missedGroup(count: 1))
        #expect(agenda.toReplan.first?.occurrenceKey == "2026-09-15")
    }

    @Test func movedOccurrenceAppearsOnItsNewDayOnly() {
        let series = task(schedule: TimeValue(date: day(17), time: LocalTime(hour: 9, minute: 0), timeZone: "Europe/Paris"), recurrence: daily)
        let moved = TimeValue(date: day(19), time: LocalTime(hour: 14, minute: 30), timeZone: "Europe/Paris")
        let rows = [OccurrenceRow(taskId: "t", key: "2026-09-17", status: .open, completedAt: nil, override: moved, successorKey: nil)]
        let today = TodayAgenda(tasks: [series], occurrences: ["t": rows], today: self.today, zone: zone)
        #expect(today.commitments.isEmpty)
        let days = DayAgenda.days(tasks: [series], occurrences: ["t": rows], from: day(18), through: day(19), zone: zone)
        let saturday = days[day(19)]?.timed ?? []
        #expect(saturday.map(\.occurrenceKey) == ["2026-09-19", "2026-09-17"])
        #expect(saturday.last?.isMoved == true)
        #expect(saturday.last?.originDate == day(17))
    }

    @Test func afterCompletionSeriesFollowsItsSuccessor() {
        let rule = RecurrenceRule.afterCompletion(AfterCompletionRule(unit: .day, interval: 90))
        let series = task(schedule: TimeValue(date: day(1)), recurrence: rule)
        let rows = [
            OccurrenceRow(taskId: "t", key: "2026-09-01~0", status: .completed, completedAt: nil, override: nil, successorKey: "2026-09-15~1"),
        ]
        let current = SeriesCalculator.currentOccurrence(task: series, rows: rows)
        #expect(current?.occurrenceKey == "2026-09-15~1")
        let agenda = TodayAgenda(tasks: [series], occurrences: ["t": rows], today: today, zone: zone)
        #expect(agenda.toReplan.map(\.occurrenceKey) == ["2026-09-15~1"])
    }

    @Test func upcomingListsWeeklyOccurrencesAndLaterSimpleTasks() {
        let weekly = task("w", schedule: TimeValue(date: today), recurrence: .fixed(FixedRule(frequency: .weekly([.thursday]), interval: 1, until: nil, count: nil)))
        let later = task("l", deadline: TimeValue(date: day(20, month: 10)))
        let agenda = UpcomingAgenda(tasks: [weekly, later], occurrences: [:], today: today, zone: zone)
        #expect(agenda.days.map(\.date) == [day(24), day(1, month: 10)])
        #expect(agenda.later.map(\.task.id) == ["l"])
    }

    @Test func simpleTaskSectionsFollowPlannedThenDeadline() {
        let planned = task("p", schedule: TimeValue(date: today, time: LocalTime(hour: 17, minute: 0), timeZone: "Europe/Paris"))
        let due = task("d", deadline: TimeValue(date: today))
        let overdue = task("o", deadline: TimeValue(date: day(12)))
        let late = task("r", schedule: TimeValue(date: day(12)))
        let agenda = TodayAgenda(tasks: [planned, due, overdue, late], occurrences: [:], today: today, zone: zone)
        #expect(agenda.commitments.map(\.task.id) == ["p"])
        #expect(agenda.deadlines.map(\.task.id) == ["d"])
        #expect(agenda.overdue.map(\.task.id) == ["o"])
        #expect(agenda.toReplan.map(\.task.id) == ["r"])
    }

    @Test func movingBackToTheOriginalValueIsNoMove() {
        let series = task(schedule: TimeValue(date: day(10), time: LocalTime(hour: 8, minute: 0), timeZone: "Europe/Paris"), recurrence: daily)
        let natural = SeriesCalculator.naturalSchedule(task: series, key: "2026-09-18")
        #expect(natural == TimeValue(date: day(18), time: LocalTime(hour: 8, minute: 0), timeZone: "Europe/Paris"))
    }

    @Test func reminderChoiceRoundTrips() {
        let rules: [ReminderRule] = [
            .beforeStart(minutes: 15), .beforeDeadline(minutes: 60), .onScheduledDay(LocalTime(hour: 9, minute: 0)),
            .onDeadlineDay(LocalTime(hour: 8, minute: 30)),
        ]
        #expect(rules.map { ReminderChoice($0) } == [.beforeStart(15), .beforeDeadline(60), .onScheduledDay, .onDeadlineDay])
        #expect(ReminderChoice(nil) == .off)
        #expect(ReminderChoice.beforeStart(1440).label == "1 jour avant")
    }
}
