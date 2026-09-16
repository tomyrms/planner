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
            case .failed(let message):
                ContentUnavailableView("Démarrage impossible", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .task { await app.launch() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, case .ready(let services) = app.phase else { return }
            Task { await services.sync.resumeIfRecoverable() }
        }
    }
}
