import SwiftUI

/// Pairing first; then the four tabs of a paired iPhone.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                ProgressView()
            case .unpaired:
                PairingView()
            case .ready(let services):
                MainTabView()
                    .environment(services)
            case .recovering(let services):
                SyncRecoveryView()
                    .environment(services)
            case .failed(let message):
                ContentUnavailableView("Démarrage impossible", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .dismissKeyboardOnBackgroundTap()
        .task { await app.launch() }
        .onChange(of: scenePhase) { _, phase in
            guard case .ready(let services) = app.phase, !services.isRecoverySuspended else { return }
            if phase == .active {
                services.reminders.requestPass()
                Task { await services.sync.resumeIfRecoverable() }
                Task { await services.resumeOnlineActions() }
            } else {
                // Leaving the foreground ends a recording without sending it.
                Task { await services.voice.appWillResignActive() }
            }
        }
    }
}
