import Foundation
import Security
import Darwin

@MainActor protocol TCLSecureSessionStore {
    func load() throws -> Data?
    func authorize() throws -> Data?
    func save(_ data: Data) throws
    func clear() throws
}

extension TCLSecureSessionStore {
    func authorize() throws -> Data? { try load() }
}

struct TCLSecureStoreError: Error { let status: OSStatus }

/// Accesses only this app's item in the existing user's login keychain.
/// Never creates/unlocks keychains or changes the user's default/search list.
@MainActor final class TCLLoginKeychainStore: TCLSecureSessionStore {
    private let service = "com.jpna.controlear.tcl"
    private let account = "tcl-home-login"

    private func withKeychain<T>(_ operation: (SecKeychain) throws -> T) throws -> T {
        guard let user = getpwuid(getuid()), let directory = user.pointee.pw_dir else { throw TCLSecureStoreError(status: errSecNoSuchKeychain) }
        let home = String(cString: directory)
        let path = home + "/Library/Keychains/login.keychain-db"
        guard FileManager.default.fileExists(atPath: path) else { throw TCLSecureStoreError(status: errSecNoSuchKeychain) }
        var handle: SecKeychain?
        let open = SecKeychainOpen(path, &handle)
        guard open == errSecSuccess, let keychain = handle else { throw TCLSecureStoreError(status: open) }
        var state: SecKeychainStatus = 0
        let status = SecKeychainGetStatus(keychain, &state)
        guard status == errSecSuccess else { throw TCLSecureStoreError(status: status) }
        guard state & SecKeychainStatus(kSecUnlockStateStatus) != 0 else { throw TCLSecureStoreError(status: errSecInteractionNotAllowed) }
        return try operation(keychain)
    }
    private func query(_ keychain: SecKeychain) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecMatchSearchList as String: [keychain]]
    }
    func load() throws -> Data? { try loadItem(allowAccessPrompt: false) }
    func authorize() throws -> Data? { try loadItem(allowAccessPrompt: true) }
    private func loadItem(allowAccessPrompt: Bool) throws -> Data? {
        try withKeychain { keychain in
            var query = query(keychain)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(KeychainAccessPolicy.query(query, allowInteraction: allowAccessPrompt) as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw TCLSecureStoreError(status: status) }
            return result as? Data
        }
    }
    func save(_ data: Data) throws {
        try withKeychain { keychain in
            let status = SecItemUpdate(KeychainAccessPolicy.query(query(keychain)) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                // Add accepts an explicit keychain; it never falls back to default.
                let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                    kSecUseKeychain as String: keychain, kSecValueData as String: data]
                let added = SecItemAdd(KeychainAccessPolicy.query(item) as CFDictionary, nil)
                guard added == errSecSuccess else { throw TCLSecureStoreError(status: added) }
            } else if status != errSecSuccess { throw TCLSecureStoreError(status: status) }
        }
    }
    func clear() throws {
        try withKeychain { keychain in
            let status = SecItemDelete(KeychainAccessPolicy.query(query(keychain)) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw TCLSecureStoreError(status: status) }
        }
    }
}
