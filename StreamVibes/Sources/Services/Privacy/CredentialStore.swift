import Foundation
import Observation
import Security

protocol CredentialBackend {
    func read(_ key: String) throws -> String?
    func write(_ value: String, for key: String) throws
    func remove(_ key: String) throws
}

enum CredentialStorageError: Error {
    case keychain(OSStatus)
    case invalidData
    case verificationFailed
}

struct KeychainCredentialBackend: CredentialBackend {
    let service: String

    private func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "settings/\(key)",
            kSecAttrSynchronizable as String: false,
        ]
    }

    func read(_ key: String) throws -> String? {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStorageError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStorageError.invalidData
        }
        return value
    }

    func write(_ value: String, for key: String) throws {
        let query = query(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStorageError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw CredentialStorageError.keychain(status)
        }
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(query(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStorageError.keychain(status)
        }
    }
}

/// Keeps credentials out of preferences. Legacy values are removed only after
/// a Keychain write has been read back successfully; failures retain the original.
@MainActor
@Observable
final class CredentialStore {
    static let shared = CredentialStore(
        keys: ["databaseURL", "aiAPIKey", "tmdbAPIKey", "omdbAPIKey"],
        backend: KeychainCredentialBackend(
            service: (Bundle.main.bundleIdentifier ?? "com.bujosa.streamvibes") + ".credentials"
        ),
        defaults: .standard
    )

    private var values: [String: String] = [:]
    private(set) var errorMessage: String?
    @ObservationIgnored private let backend: any CredentialBackend
    @ObservationIgnored private let defaults: UserDefaults

    init(keys: [String], backend: any CredentialBackend, defaults: UserDefaults) {
        self.backend = backend
        self.defaults = defaults
        for key in keys {
            let legacy = defaults.string(forKey: key)
            values[key] = legacy ?? ""
            do {
                if let stored = try backend.read(key) {
                    values[key] = stored
                    defaults.removeObject(forKey: key)
                } else if let legacy, !legacy.isEmpty {
                    try backend.write(legacy, for: key)
                    guard try backend.read(key) == legacy else {
                        throw CredentialStorageError.verificationFailed
                    }
                    defaults.removeObject(forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            } catch {
                reportFailure()
            }
        }
    }

    func value(for key: String) -> String {
        values[key] ?? ""
    }

    @discardableResult
    func set(_ value: String, for key: String) -> Bool {
        do {
            if value.isEmpty {
                try backend.remove(key)
                guard try backend.read(key) == nil else {
                    throw CredentialStorageError.verificationFailed
                }
            } else {
                try backend.write(value, for: key)
                guard try backend.read(key) == value else {
                    throw CredentialStorageError.verificationFailed
                }
            }
            values[key] = value
            defaults.removeObject(forKey: key)
            errorMessage = nil
            return true
        } catch {
            reportFailure()
            return false
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func reportFailure() {
        errorMessage = "Could not verify credentials in macOS Keychain. Existing settings were kept. Unlock your login keychain and reopen the app to retry migration."
    }
}
