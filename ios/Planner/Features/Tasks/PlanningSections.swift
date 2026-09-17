import SwiftUI
import UIKit
import UserNotifications

/// Rappel (02_Design/05_Calendar_Task_UX.md): one reminder, options depending on the available base, and the
/// state on this iPhone, never confused with a displayed notification
/// (03_iOS/03_Notifications_EventKit_Widgets.md §1.1, §1.6).
struct ReminderSection: View {
    @Binding var reminder: ReminderRule?
    let schedule: TimeValue?
    let deadline: TimeValue?
    /// A series only takes reminders relative to each occurrence.
    let allowsAbsolute: Bool
    /// Identifier of the saved reminder when the draft still shows it.
    let savedId: String?
    let isNew: Bool
    @Environment(AppServices.self) private var services

    var body: some View {
        Section {
            Picker("Rappel", selection: choice) {
                ForEach(choices, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            switch reminder {
            case .onScheduledDay?, .onDeadlineDay?:
                DatePicker("Heure du rappel", selection: dayTime, displayedComponents: .hourAndMinute)
            case .absolute?:
                DatePicker("Date du rappel", selection: absoluteDate, displayedComponents: [.date, .hourAndMinute])
            default:
                EmptyView()
            }
            if reminder != nil, let status {
                Label(status.text, systemImage: status.symbol)
                    .foregroundStyle(status.warning ? Color.orange : Color.secondary)
                if status.offersSettings, let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    Link("Ouvrir les réglages de notifications", destination: url)
                }
            }
        } header: {
            Text("Rappel")
        } footer: {
            if reminder != nil && isNew && services.reminders.authorization == .notDetermined {
                Text("À l’enregistrement, l’iPhone demandera l’autorisation d’afficher les rappels de vos tâches.")
            }
        }
    }

    // MARK: - Choices

    private var baseDay: CivilDate {
        schedule?.date ?? deadline?.date ?? .today()
    }

    /// Offered options: only those whose base exists, plus the current one even when its base disappeared.
    private var choices: [ReminderChoice] {
        var result: [ReminderChoice] = [.off]
        if let schedule {
            if schedule.time != nil {
                result += [0, 5, 15, 30, 60, 1440].map(ReminderChoice.beforeStart)
            } else {
                result.append(.onScheduledDay)
            }
        }
        if let deadline {
            if deadline.time != nil {
                result += [0, 60, 1440].map(ReminderChoice.beforeDeadline)
            } else {
                result.append(.onDeadlineDay)
            }
        }
        if allowsAbsolute { result.append(.absolute) }
        let current = ReminderChoice(reminder)
        if !result.contains(current) { result.append(current) }
        return result
    }

    private var choice: Binding<ReminderChoice> {
        Binding(
            get: { ReminderChoice(reminder) },
            set: { option in reminder = rule(for: option) }
        )
    }

    private var currentDayTime: LocalTime {
        switch reminder {
        case .onScheduledDay(let time)?, .onDeadlineDay(let time)?: return time
        default: return LocalTime(hour: 9, minute: 0)
        }
    }

    private func rule(for option: ReminderChoice) -> ReminderRule? {
        switch option {
        case .off:
            return nil
        case .beforeStart(let minutes):
            return .beforeStart(minutes: minutes)
        case .beforeDeadline(let minutes):
            return .beforeDeadline(minutes: minutes)
        case .onScheduledDay:
            return .onScheduledDay(currentDayTime)
        case .onDeadlineDay:
            return .onDeadlineDay(currentDayTime)
        case .absolute:
            if case .absolute(let value)? = reminder { return .absolute(value) }
            return .absolute(TimeValue(date: baseDay, time: LocalTime(hour: 9, minute: 0), timeZone: TimeZone.current.identifier))
        }
    }

    private var dayTime: Binding<Date> {
        Binding(
            get: { LocalTime.date(currentDayTime, on: baseDay) },
            set: { date in
                switch reminder {
                case .onScheduledDay?: reminder = .onScheduledDay(LocalTime(date))
                case .onDeadlineDay?: reminder = .onDeadlineDay(LocalTime(date))
                default: break
                }
            }
        )
    }

    private var absoluteDate: Binding<Date> {
        Binding(
            get: {
                guard case .absolute(let value)? = reminder else { return Date() }
                return value.instant ?? value.date.noon()
            },
            set: { date in
                reminder = .absolute(TimeValue(date: CivilDate(date), time: LocalTime(date), timeZone: TimeZone.current.identifier))
            }
        )
    }

    // MARK: - State

    private struct Status {
        let text: String
        let symbol: String
        var warning = false
        var offersSettings = false
    }

    private var status: Status? {
        guard let reminder else { return nil }
        let denied = services.reminders.authorization == .denied
        if ReminderMath.trigger(reminder, schedule: schedule, deadline: deadline, deviceZone: .current) == .baseMissing {
            let text = isNew
                ? "Ce rappel a besoin d’une date ou d’une heure : choisissez-en une ou un autre rappel."
                : "Base du rappel manquante : il reprendra quand la date ou l’heure reviendra."
            return Status(text: text, symbol: "exclamationmark.triangle", warning: true)
        }
        if denied {
            return Status(text: "Notifications désactivées : aucune alerte ne sera affichée.", symbol: "bell.slash", warning: true, offersSettings: true)
        }
        if isNew || savedId == nil {
            return Status(text: "Sera programmé sur cet iPhone à l’enregistrement.", symbol: "bell")
        }
        var state: ReminderMath.State?
        if let savedId { state = services.reminders.displayState(reminderId: savedId) }
        switch state {
        case .scheduled?:
            return Status(text: "Programmé sur cet iPhone.", symbol: "bell.badge")
        case .pendingWindow?, .pendingCapacity?:
            return Status(text: "En attente de programmation : il sera réexaminé aux prochaines ouvertures.", symbol: "clock")
        case .notificationsDisabled?:
            return Status(text: "Notifications désactivées : aucune alerte ne sera affichée.", symbol: "bell.slash", warning: true, offersSettings: true)
        case .baseMissing?:
            return Status(text: "Base du rappel manquante.", symbol: "exclamationmark.triangle", warning: true)
        case .missed?:
            return Status(text: "Rappel manqué : son heure est passée sans programmation.", symbol: "bell.slash", warning: true)
        case .displayUnknown?:
            return Status(text: "Heure du rappel passée.", symbol: "clock.badge.checkmark")
        case .removed?:
            return nil
        case .needsScheduling?, nil:
            return Status(text: "Sera programmé sur cet iPhone.", symbol: "bell")
        }
    }
}

/// The picker value behind a reminder rule: its kind, and the offset of relative rules.
nonisolated enum ReminderChoice: Hashable, Sendable {
    case off
    case beforeStart(Int)
    case onScheduledDay
    case beforeDeadline(Int)
    case onDeadlineDay
    case absolute

    init(_ rule: ReminderRule?) {
        switch rule {
        case nil: self = .off
        case .beforeStart(let minutes)?: self = .beforeStart(minutes)
        case .beforeDeadline(let minutes)?: self = .beforeDeadline(minutes)
        case .onScheduledDay?: self = .onScheduledDay
        case .onDeadlineDay?: self = .onDeadlineDay
        case .absolute?: self = .absolute
        }
    }

    var label: String {
        switch self {
        case .off: "Aucun"
        case .beforeStart(0): "À l’heure prévue"
        case .beforeStart(let minutes): ReminderRule.offsetText(minutes) + " avant"
        case .onScheduledDay: "Le jour prévu, à une heure"
        case .beforeDeadline(0): "À l’heure de l’échéance"
        case .beforeDeadline(let minutes): ReminderRule.offsetText(minutes) + " avant l’échéance"
        case .onDeadlineDay: "Le jour de l’échéance, à une heure"
        case .absolute: "À une date précise"
        }
    }
}

/// Répétition (02_Design/05_Calendar_Task_UX.md § Récurrence): at fixed dates or after completion, said in full,
/// with a readable summary. Not a full RRULE (04_Backend/03_Data_Model.md §4).
struct RecurrenceSection: View {
    @Binding var recurrence: RecurrenceRule?
    /// First occurrence: the defaults follow its weekday and day of month.
    let anchor: CivilDate
    let allowsNone: Bool

    private nonisolated enum Mode: Hashable {
        case off, fixed, afterCompletion
    }

    private nonisolated enum Frequency: Hashable {
        case daily, weekly, monthlyDay, monthlyLast
    }

    private nonisolated enum End: Hashable {
        case never, until, count
    }

    var body: some View {
        Section {
            Picker("Répétition", selection: mode) {
                if allowsNone { Text("Aucune").tag(Mode.off) }
                Text("À date fixe").tag(Mode.fixed)
                Text("Après l’avoir faite").tag(Mode.afterCompletion)
            }
            if case .fixed(let rule)? = recurrence {
                fixedFields(rule)
            } else if case .afterCompletion(let rule)? = recurrence {
                Stepper(value: afterInterval, in: 1...365) {
                    Text(rule.interval == 1 ? "Intervalle : 1" : "Intervalle : \(rule.interval)")
                }
                Picker("Unité", selection: afterUnit) {
                    Text(rule.interval == 1 ? "jour" : "jours").tag(AfterCompletionRule.Unit.day)
                    Text(rule.interval == 1 ? "semaine" : "semaines").tag(AfterCompletionRule.Unit.week)
                    Text("mois").tag(AfterCompletionRule.Unit.month)
                }
            }
        } header: {
            Text("Répétition")
        } footer: {
            if let recurrence {
                Text(footerText(recurrence))
            }
        }
    }

    private func footerText(_ recurrence: RecurrenceRule) -> String {
        switch recurrence {
        case .fixed: recurrence.summary + ". Les dates suivent le calendrier, même si une occurrence n’est pas faite."
        case .afterCompletion: recurrence.summary + ". La prochaine date se calcule quand vous la terminez."
        }
    }

    @ViewBuilder
    private func fixedFields(_ rule: FixedRule) -> some View {
        Picker("Fréquence", selection: frequency) {
            Text("Chaque jour").tag(Frequency.daily)
            Text("Certains jours de la semaine").tag(Frequency.weekly)
            Text("Chaque mois, à une date").tag(Frequency.monthlyDay)
            Text("Chaque mois, le dernier jour").tag(Frequency.monthlyLast)
        }
        Stepper(value: fixedInterval, in: 1...365) {
            Text(intervalText(rule))
        }
        if case .weekly(let days) = rule.frequency {
            WeekdayPicker(selection: days) { updated in
                update { $0.frequency = .weekly(updated) }
            }
        }
        if case .monthlyDay = rule.frequency {
            Picker("Jour du mois", selection: monthDay) {
                ForEach(1...31, id: \.self) { day in
                    Text("le \(day)").tag(day)
                }
            }
        }
        Picker("Fin", selection: end) {
            Text("Jamais").tag(End.never)
            Text("À une date").tag(End.until)
            Text("Après un nombre de fois").tag(End.count)
        }
        if rule.until != nil {
            DatePicker("Jusqu’au", selection: until, in: anchor.noon()..., displayedComponents: .date)
        }
        if let count = rule.count {
            Stepper(value: countBinding, in: 1...999) {
                Text(count == 1 ? "1 fois" : "\(count) fois")
            }
        }
    }

    private func intervalText(_ rule: FixedRule) -> String {
        let n = rule.interval
        switch rule.frequency {
        case .daily: return n == 1 ? "Tous les jours" : "Tous les \(n) jours"
        case .weekly: return n == 1 ? "Toutes les semaines" : "Toutes les \(n) semaines"
        case .monthlyDay, .monthlyLast: return n == 1 ? "Tous les mois" : "Tous les \(n) mois"
        }
    }

    // MARK: - Bindings

    private var fixedRule: FixedRule? {
        if case .fixed(let rule)? = recurrence { return rule }
        return nil
    }

    private func update(_ change: (inout FixedRule) -> Void) {
        guard var rule = fixedRule else { return }
        change(&rule)
        recurrence = .fixed(rule)
    }

    private var mode: Binding<Mode> {
        Binding(
            get: {
                switch recurrence {
                case nil: Mode.off
                case .fixed?: Mode.fixed
                case .afterCompletion?: Mode.afterCompletion
                }
            },
            set: { mode in
                switch mode {
                case .off:
                    recurrence = nil
                case .fixed:
                    if fixedRule == nil { recurrence = .fixed(FixedRule(frequency: .daily, interval: 1, until: nil, count: nil)) }
                case .afterCompletion:
                    if case .afterCompletion? = recurrence { return }
                    recurrence = .afterCompletion(AfterCompletionRule(unit: .week, interval: 1))
                }
            }
        )
    }

    private var frequency: Binding<Frequency> {
        Binding(
            get: {
                switch fixedRule?.frequency {
                case .weekly?: .weekly
                case .monthlyDay?: .monthlyDay
                case .monthlyLast?: .monthlyLast
                default: .daily
                }
            },
            set: { value in
                update { rule in
                    switch value {
                    case .daily: rule.frequency = .daily
                    case .weekly: rule.frequency = .weekly([anchor.weekday])
                    case .monthlyDay: rule.frequency = .monthlyDay(anchor.day)
                    case .monthlyLast: rule.frequency = .monthlyLast
                    }
                }
            }
        )
    }

    private var fixedInterval: Binding<Int> {
        Binding(get: { fixedRule?.interval ?? 1 }, set: { value in update { $0.interval = value } })
    }

    private var monthDay: Binding<Int> {
        Binding(
            get: {
                if case .monthlyDay(let day)? = fixedRule?.frequency { return day }
                return anchor.day
            },
            set: { value in update { $0.frequency = .monthlyDay(value) } }
        )
    }

    private var end: Binding<End> {
        Binding(
            get: {
                if fixedRule?.until != nil { return .until }
                if fixedRule?.count != nil { return .count }
                return .never
            },
            set: { value in
                update { rule in
                    // `until` and `count` never go together.
                    rule.until = value == .until ? (rule.until ?? anchor.adding(months: 1)) : nil
                    rule.count = value == .count ? (rule.count ?? 10) : nil
                }
            }
        )
    }

    private var until: Binding<Date> {
        Binding(
            get: { fixedRule?.until?.noon() ?? anchor.noon() },
            set: { date in update { $0.until = max(CivilDate(date), anchor) } }
        )
    }

    private var countBinding: Binding<Int> {
        Binding(get: { fixedRule?.count ?? 1 }, set: { value in update { $0.count = value } })
    }

    private var afterRule: AfterCompletionRule? {
        if case .afterCompletion(let rule)? = recurrence { return rule }
        return nil
    }

    private var afterInterval: Binding<Int> {
        Binding(
            get: { afterRule?.interval ?? 1 },
            set: { value in
                guard var rule = afterRule else { return }
                rule.interval = value
                recurrence = .afterCompletion(rule)
            }
        )
    }

    private var afterUnit: Binding<AfterCompletionRule.Unit> {
        Binding(
            get: { afterRule?.unit ?? .week },
            set: { value in
                guard var rule = afterRule else { return }
                rule.unit = value
                recurrence = .afterCompletion(rule)
            }
        )
    }
}

/// Seven toggles, Monday first; the last selected day cannot be removed.
struct WeekdayPicker: View {
    let selection: [Weekday]
    let onChange: ([Weekday]) -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(Weekday.allCases, id: \.self) { day in
                let isOn = selection.contains(day)
                Button {
                    toggle(day)
                } label: {
                    Text(String(day.shortLabel.dropLast()))
                        .font(.caption.weight(isOn ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.comfort)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.medium)
                                .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.label)
                .accessibilityAddTraits(isOn ? AccessibilityTraits.isSelected : [])
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func toggle(_ day: Weekday) {
        var days = selection
        if let index = days.firstIndex(of: day) {
            guard days.count > 1 else { return }
            days.remove(at: index)
        } else {
            days.append(day)
        }
        onChange(Weekday.allCases.filter(days.contains))
    }
}
