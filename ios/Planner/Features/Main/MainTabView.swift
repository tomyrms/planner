import SwiftUI

/// Four native destinations; quick capture is a tab accessory action, never a fifth destination.
struct MainTabView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = Destination.today
    @State private var addingTask = false
    @State private var navigationTask: Task<Void, Never>?

    private enum Destination: Hashable { case today, calendar, assistant, lists }

    var body: some View {
        @Bindable var navigator = services.navigator
        TabView(selection: Binding(get: { selection }, set: select)) {
            Tab("Aujourd’hui", systemImage: "sun.max", value: Destination.today) {
                TodayView()
            }
            Tab("Calendrier", systemImage: "calendar", value: Destination.calendar) {
                CalendarView()
            }
            Tab("Assistant", systemImage: "text.bubble", value: Destination.assistant) {
                AssistantView()
            }
            Tab("Listes", systemImage: "list.bullet", value: Destination.lists) {
                ListsView()
            }
        }
        .tabViewBottomAccessory {
            QuickCaptureAccessory(
                onAddTask: { addingTask = true },
                onOpenAssistant: { selection = .assistant }
            )
        }
        .overlay(alignment: .bottom) {
            if let offer = services.undo.current {
                UndoBanner(message: offer.message) {
                    Task { await services.undo.undo() }
                } onClose: {
                    services.undo.dismiss()
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, 64)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: services.undo.current?.id)
        .sheet(isPresented: $addingTask) {
            TaskEditorView(mode: .create(projectId: nil, schedule: nil))
        }
        .sheet(item: $navigator.target) { target in
            OpenTargetView(target: target)
        }
        .onDisappear { navigationTask?.cancel() }
    }

    private func select(_ destination: Destination) {
        guard destination != selection else { return }
        navigationTask?.cancel()
        if services.voice.phase == .recording || services.voice.phase == .finishing || services.voice.isPreparingRecording {
            navigationTask = Task {
                await services.voice.appWillResignActive()
                guard !Task.isCancelled else { return }
                selection = destination
                navigationTask = nil
            }
        } else {
            selection = destination
        }
    }
}

/// Toast after a manual action; the durable way back stays in Terminées and Corbeille.
struct UndoBanner: View {
    let message: String
    let onUndo: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Annuler", action: onUndo)
                .font(.subheadline.weight(.semibold))
            Button("Fermer", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
        }
        .padding(.leading, Spacing.lg)
        .padding(.vertical, Spacing.xs)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium))
        .accessibilityElement(children: .contain)
    }
}

struct ComingSoonView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
                .navigationTitle(title)
        }
    }
}
