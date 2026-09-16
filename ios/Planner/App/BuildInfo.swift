import Foundation
import UIKit

/// Version, build and device, shown in Settings and sent to the server.
struct BuildInfo {
    let version: String
    let build: String
    let systemVersion: String
    let hardwareModel: String

    static let current = BuildInfo(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
        systemVersion: UIDevice.current.systemVersion,
        hardwareModel: machineIdentifier()
    )

    /// `X-Client-Version`, checked by the server against its minimum version (426 CLIENT_TOO_OLD).
    var clientVersionHeader: String {
        "\(version) (build \(build))"
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
