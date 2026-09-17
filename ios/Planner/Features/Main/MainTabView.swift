import SwiftUI

/// Four destinations (02_Design/05_Calendar_Task_UX.md); adding is a toolbar action, never a tab.
struct MainTabView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var navigator = services.navigator
        TabView {
            Tab("Aujourd’hui", systemImage: "sun.max") {
                TodayView()
            }
            Tab("Calendrier", systemImage: "calendar") {
                CalendarView()
            }
            Tab("Assistant", systemImage: "text.bubble") {
                AssistantView()
            }
            Tab("Listes", systemImage: "list.bullet") {
                ListsView()
            }
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
        .animation(.easeInOut(duration: 0.22), value: services.undo.current?.id)
        .sheet(item: $navigator.target) { target in
            OpenTargetView(target: target)
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
