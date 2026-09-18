import SwiftUI

/// Four native tab destinations with a central capture action between Calendar and Assistant.
struct MainTabView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selection = Destination.today
    @State private var addingTask = false
    @State private var navigationTask: Task<Void, Never>?
    @State private var keyboardVisible = false
    @State private var barWidth: CGFloat = 320
    @State private var globalCaptureUsed = false
    @State private var globalCaptureVisible = false

    private nonisolated enum Destination: Hashable { case today, calendar, assistant, lists }

    var body: some View {
        @Bindable var navigator = services.navigator
        // Reserve real layout space below TabView. A safeAreaInset outside the native tab
        // container does not reliably reach its child NavigationStacks (notably the composer).
        VStack(spacing: 0) {
            TabView(selection: Binding(get: { selection }, set: { destination in select(destination) })) {
                Tab("Mes tâches", systemImage: "checklist", value: Destination.today) {
                    TasksHomeView()
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
                Tab("Calendrier", systemImage: "calendar", value: Destination.calendar) {
                    CalendarView()
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
                Tab("Assistant", systemImage: "text.bubble", value: Destination.assistant) {
                    AssistantView(recordingHandledByNavigation: globalCaptureVisible && !keyboardVisible)
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
                Tab("Listes", systemImage: "list.bullet", value: Destination.lists) {
                    ListsView()
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
            }
            if !keyboardVisible { bottomBar }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: Spacing.sm) {
                if selection != .assistant && !globalCaptureVisible &&
                    (globalCaptureUsed || services.voice.draft != nil || services.assistant.pending?.transcriptionId != nil) {
                    VoiceCaptureFeedback {
                        // The only navigation associated with capture is a deliberate tap on Voir.
                        select(.assistant)
                    }
                }
                if let offer = services.undo.current {
                    UndoBanner(message: offer.message) {
                        Task { await services.undo.undo() }
                    } onClose: {
                        services.undo.dismiss()
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, keyboardVisible ? 8 : 94)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: services.undo.current?.id)
        .sheet(isPresented: $addingTask) {
            TaskEditorView(mode: .create(projectId: nil, schedule: nil))
        }
        .sheet(item: $navigator.target) { target in
            OpenTargetView(target: target)
        }
        .onDisappear { navigationTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 0) {
            destination(.today, title: "Mes tâches", symbol: "checklist")
            destination(.calendar, title: "Calendrier", symbol: "calendar")
            QuickCaptureAccessory(panelWidth: max(240, barWidth - 16),
                                  onAddTask: { addingTask = true },
                                  onCaptureStart: { globalCaptureUsed = true },
                                  onCaptureVisibilityChange: { globalCaptureVisible = $0 })
                .frame(width: 64)
                .offset(y: -10)
                .zIndex(1)
            destination(.assistant, title: "Assistant", symbol: "text.bubble")
            destination(.lists, title: "Listes", symbol: "list.bullet")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 6)
        .background {
            if reduceTransparency {
                Capsule().fill(Color(uiColor: .secondarySystemBackground))
            } else {
                Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation principale")
    }

    private func destination(_ value: Destination, title: String, symbol: String) -> some View {
        let selected = selection == value
        return Button { select(value) } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: typeSize.isAccessibilitySize ? 24 : 21, weight: selected ? .semibold : .regular))
                if !typeSize.isAccessibilitySize {
                    Text(title).font(.caption2).lineLimit(1)
                }
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint("Onglet")
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
