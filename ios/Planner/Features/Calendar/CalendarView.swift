import SwiftUI

/// Calendrier (ADR-024, 02_Design/05_Calendar_Task_UX.md): a compact month to pick a day, and that day's agenda
/// below; "Ouvrir le jour" shows the agenda full screen with previous and next day.
struct CalendarView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @State private var today = CivilDate.today()
    @State private var selected = CivilDate.today()
    @State private var month = CivilDate.today().firstOfMonth
    @State private var creating = false

    var body: some View {
        let grid = MonthGrid.days(for: month)
        let days = services.agenda.days(from: grid.first ?? month, through: grid.last ?? month)
        NavigationStack {
            List {
                Section {
                    MonthView(month: month, selected: selected, today: today, counts: days.mapValues(\.count), onSelect: select, onShift: shift)
                }
                DayAgendaSections(agenda: days[selected] ?? DayAgenda(), heading: DateText.heading(selected))
                Section {
                    NavigationLink("Ouvrir le jour en plein écran") {
                        DayScreen(date: selected)
                    }
                }
            }
            .navigationTitle("Calendrier")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Aujourd’hui") { select(today) }
                        .disabled(selected == today)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Ajouter une tâche", systemImage: "plus") { creating = true }
                }
            }
            .sheet(isPresented: $creating) {
                TaskEditorView(mode: .create(projectId: nil, schedule: TimeValue(date: selected)))
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                let now = CivilDate.today()
                if now != today {
                    if selected == today { select(now) }
                    today = now
                }
            }
        }
    }

    private func select(_ date: CivilDate) {
        selected = date
        month = date.firstOfMonth
    }

    /// Another month keeps the same day number when it exists, so that the agenda below stays meaningful.
    private func shift(_ months: Int) {
        let target = month.adding(months: months)
        let day = min(selected.day, CivilDate.monthLength(year: target.year, month: target.month))
        let date = CivilDate(year: target.year, month: target.month, day: day)
        select(target.year == today.year && target.month == today.month ? today : date)
    }
}

/// Month grid: Monday first, a dot for days with something (a shape, not only a colour), the selected day
/// announced with its content. Cells stay at least 44 pt high; the day agenda is the accessible alternative.
struct MonthView: View {
    let month: CivilDate
    let selected: CivilDate
    let today: CivilDate
    let counts: [CivilDate: Int]
    let onSelect: (CivilDate) -> Void
    let onShift: (Int) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack {
                Button("Mois précédent", systemImage: "chevron.left") { onShift(-1) }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
                Spacer()
                Text(month.noon().formatted(.dateTime.month(.wide).year()).capitalizedFirst)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Mois suivant", systemImage: "chevron.right") { onShift(1) }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
            }
            .buttonStyle(.borderless)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Weekday.allCases, id: \.self) { day in
                    Text(String(day.shortLabel.prefix(1)).uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                ForEach(MonthGrid.days(for: month), id: \.self) { date in
                    DayCell(
                        date: date,
                        inMonth: date.month == month.month,
                        isToday: date == today,
                        isSelected: date == selected,
                        count: counts[date] ?? 0
                    ) {
                        onSelect(date)
                    }
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.vertical, Spacing.xs)
    }
}

struct DayCell: View {
    let date: CivilDate
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text("\(date.day)")
                    .font(.callout.monospacedDigit())
                    .fontWeight(isToday || isSelected ? .semibold : .regular)
                    .foregroundStyle(numberColor)
                    .frame(minWidth: 32, minHeight: 32)
                    .background {
                        if isSelected {
                            Circle().fill(Color.accentColor)
                        } else if isToday {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                    }
                Circle()
                    .fill(count > 0 ? Color.secondary : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: TouchTarget.comfort + 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : [])
    }

    private var numberColor: Color {
        if isSelected { return .white }
        if isToday { return .accentColor }
        return inMonth ? .primary : .secondary
    }

    /// "mardi 15 septembre, aujourd’hui, 3 éléments" (the trait adds "sélectionné").
    private var accessibilityText: String {
        var text = date.noon().formatted(.dateTime.weekday(.wide).day().month(.wide))
        if isToday { text += ", aujourd’hui" }
        switch count {
        case 0: text += ", rien de prévu"
        case 1: text += ", 1 élément"
        default: text += ", \(count) éléments"
        }
        return text
    }
}

/// One day: without time first, then chronological, then deadlines only.
struct DayAgendaSections: View {
    let agenda: DayAgenda
    let heading: String

    var body: some View {
        if agenda.isEmpty {
            Section(heading) {
                Text("Rien de prévu ce jour.")
                    .foregroundStyle(.secondary)
            }
        } else {
            if !agenda.untimed.isEmpty {
                Section("À faire ce jour") {
                    ForEach(agenda.untimed) { TaskRow(item: $0, context: .day) }
                }
            }
            if !agenda.timed.isEmpty {
                Section(agenda.untimed.isEmpty ? heading : "Dans la journée") {
                    ForEach(agenda.timed) { TaskRow(item: $0, context: .day) }
                }
            }
            if !agenda.deadlines.isEmpty {
                Section("Échéances") {
                    ForEach(agenda.deadlines) { TaskRow(item: $0, context: .day) }
                }
            }
        }
    }
}

/// The agenda of one day, full screen, with previous and next day.
struct DayScreen: View {
    @State private var date: CivilDate
    @Environment(AppServices.self) private var services
    @State private var creating = false

    init(date: CivilDate) {
        _date = State(initialValue: date)
    }

    var body: some View {
        let agenda = services.agenda.days(from: date, through: date)[date] ?? DayAgenda()
        List {
            DayAgendaSections(agenda: agenda, heading: "Ce jour")
        }
        .navigationTitle(DateText.heading(date))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Jour précédent", systemImage: "chevron.left") { date = date.adding(days: -1) }
                Button("Jour suivant", systemImage: "chevron.right") { date = date.adding(days: 1) }
                Button("Ajouter une tâche", systemImage: "plus") { creating = true }
            }
        }
        .sheet(isPresented: $creating) {
            TaskEditorView(mode: .create(projectId: nil, schedule: TimeValue(date: date)))
        }
    }
}
