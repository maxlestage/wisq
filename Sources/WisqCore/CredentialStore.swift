import Foundation
#if canImport(Security)
import Security
#endif

/// Secrets never sit in the machine list. They go here, keyed by `credentialRef`.
public protocol CredentialStore: Sendable {
    func secret(for ref: String) throws -> String?
    func setSecret(_ secret: String?, for ref: String) throws
}

#if canImport(Security)
/// Keychain-backed store. Items are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// so a background reconnect works, but the secret never rides an iCloud backup.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = "app.wisq.credentials") {
        self.service = service
    }

    public func secret(for ref: String) throws -> String? {
        var query = baseQuery(ref: ref)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
                throw WisqError.storageFailure("entrée trousseau illisible")
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw WisqError.storageFailure("trousseau (OSStatus \(status))")
        }
    }

    public func setSecret(_ secret: String?, for ref: String) throws {
        let query = baseQuery(ref: ref)

        guard let secret, let data = secret.data(using: .utf8) else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw WisqError.storageFailure("suppression trousseau (OSStatus \(status))")
            }
            return
        }

        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw WisqError.storageFailure("mise à jour trousseau (OSStatus \(updateStatus))")
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw WisqError.storageFailure("écriture trousseau (OSStatus \(addStatus))")
        }
    }

    private func baseQuery(ref: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
        ]
    }
}
#endif

/// In-memory store for tests and previews.
public final class EphemeralCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init(seed: [String: String] = [:]) {
        self.storage = seed
    }

    public func secret(for ref: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[ref]
    }

    public func setSecret(_ secret: String?, for ref: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[ref] = secret
    }
}
