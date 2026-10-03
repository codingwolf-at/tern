import Foundation
import Security

/// An OAuth user access token, plus refresh details when the GitHub App issues expiring tokens.
struct GitHubCredential: Codable, Sendable, Hashable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?

    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(60)
    }
}

/// Where the GitHub credential lives. Never the JSON state file or user defaults.
protocol GitHubCredentialStore: Sendable {
    func load() throws -> GitHubCredential?
    func save(_ credential: GitHubCredential) throws
    func delete() throws
}

struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// Stores the credential as a generic password in the user's keychain.
struct KeychainCredentialStore: GitHubCredentialStore {
    var service = "so.plane.tern.github"
    var account = "user-access-token"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> GitHubCredential? {
        var item: CFTypeRef?
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(GitHubCredential.self, from: data)
    }

    func save(_ credential: GitHubCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrLabel as String] = "Tern GitHub access"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
