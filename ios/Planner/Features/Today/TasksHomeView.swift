import SwiftUI

/// One destination and one native navigation stack; the picker only changes the tasks being shown.
struct TasksHomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selection: TasksHomeSelection = .today

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Afficher").foregroundStyle(.secondary)
                            picker
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack {
                            Text("Afficher").foregroundStyle(.secondary)
                            Spacer(minLength: Spacing.sm)
                            picker
                        }
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.xs)
                content
                    .id(selection)
            }
            .navigationTitle("Mes tâches")
        }
    }

    private var picker: some View {
        Picker("Vue des tâches", selection: $selection) {
            ForEach(TasksHomeSelection.allCases) { option in
                Label(option.title, systemImage: option.symbol).tag(option)
            }
        }
        .pickerStyle(.menu)
        .frame(minHeight: TouchTarget.comfort)
        .accessibilityHint("Choisit les tâches affichées dans cet onglet.")
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .today:
            TodayView(embedded: true)
        case .all:
            TaskListScreen(title: "Toutes les tâches", filter: .allActive, context: .list, embedded: true)
        case .inbox:
            TaskListScreen(title: "Inbox", filter: .inbox, context: .list, embedded: true)
        case .upcoming:
            UpcomingView(embedded: true)
        }
    }
}

nonisolated enum TasksHomeSelection: String, CaseIterable, Identifiable, Sendable {
    case today, all, inbox, upcoming

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Aujourd’hui"
        case .all: "Toutes les tâches"
        case .inbox: "Inbox"
        case .upcoming: "À venir"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .all: "checklist"
        case .inbox: "tray"
        case .upcoming: "calendar"
        }
    }
}
