import Foundation
import Security

/// One Keychain generic-password item per account (keyed by DID) under a single service, each
/// holding a JSON-encoded value.
///
/// Items are `WhenUnlockedThisDeviceOnly`, keeping DPoP private keys out of backups and device
/// migration. No access group (nothing else shares the tokens) and, on macOS, no
/// data-protection keychain, which unsigned debug builds can't use.
struct KeychainAccountStore<Value: Codable> {
    let service: String

    /// Every stored value, in the order its account was first saved.
    func all() throws -> [Value] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError(status: status)
        }
        // The legacy macOS keychain can't return data for a match-all query, so each item's
        // data is read separately.
        return try items
            .compactMap { item -> (account: String, added: Double)? in
                guard let account = item[kSecAttrAccount as String] as? String else { return nil }
                return (account, Self.addedOrder(item))
            }
            .sorted { $0.added < $1.added }
            .compactMap { try value(for: $0.account) }
    }

    func value(for account: String) throws -> Value? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    /// Updates the account's item in place, adding it only if absent. Never delete-then-add: a
    /// failed add would lose a session whose refresh token the server has already rotated.
    func save(_ value: Value, for account: String) throws {
        let data = try JSONEncoder().encode(value)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // The keychain's own creation date is only second-precise on macOS, so the add order is
        // recorded explicitly; updates leave it alone.
        attributes[kSecAttrGeneric as String] = Data(String(Date().timeIntervalSince1970).utf8)
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private static func addedOrder(_ item: [String: Any]) -> Double {
        guard let data = item[kSecAttrGeneric as String] as? Data else { return 0 }
        return Double(String(decoding: data, as: UTF8.self)) ?? 0
    }
}

struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "error \(status)"
        return "Couldn't access the Keychain (\(message))."
    }
}
