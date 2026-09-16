import SwiftUI
import UIKit

/// Step 4 placeholder (05_Project/01_Roadmap.md): proves that the app builds and installs, and shows
/// the values the environment table needs (03_iOS/05_Build_IPA_Sideload.md §1).
struct RootView: View {
    private let info = BuildInfo.current

    var body: some View {
        NavigationStack {
            List {
                Section("Application") {
                    LabeledContent("Version", value: info.version)
                    LabeledContent("Build", value: info.build)
                }
                Section {
                    LabeledContent("iOS", value: info.systemVersion)
                    LabeledContent("Modèle", value: info.hardwareModel)
                } header: {
                    Text("Appareil")
                } footer: {
                    Text("Valeurs à reporter dans le tableau d’environnement.")
                }
            }
            .navigationTitle("Planner")
        }
    }
}

struct BuildInfo {
    let version: String
    let build: String
    let systemVersion: String
    let hardwareModel: String

    static var current: BuildInfo {
        let bundle = Bundle.main
        return BuildInfo(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            systemVersion: UIDevice.current.systemVersion,
            hardwareModel: machineIdentifier()
        )
    }

    /// Identifier such as "iPhone17,3": `UIDevice.model` only says "iPhone".
    private static func machineIdentifier() -> String {
        var system = utsname()
        _ = uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

#Preview {
    RootView()
}
