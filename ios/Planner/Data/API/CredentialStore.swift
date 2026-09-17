import Foundation
import Security

/// What survives a relaunch: the server chosen at pairing and the rotating refresh token.
/// The access token stays in memory only (04_Backend/06_Security_Privacy.md).
nonisolated struct StoredSession: Codable, Equatable, Sendable {
    var apiBaseURL: URL
    var deviceId: String
    var refreshToken: String
    /// Absent in older installations until their existing refresh session proves its owner.
    var userId: String? = nil
}

nonisolated struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// One Keychain item, readable after the first unlock (background sync) and never migrated to another device.
nonisolated struct CredentialStore: Sendable {
    private let service = "planner.session"
    private let account: String

    init(account: String = "device") { self.account = account }

    func load() throws -> StoredSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(StoredSession.self, from: data)
    }

    func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
        let item = baseQuery.merging(attributes) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
