import Foundation
import LocalAuthentication
import Security

/// The everyday space's credential, kept in the Keychain behind Face ID and
/// shared with the extension through the App Group access group.
enum EverydayCredentialStore {
    private static let account = "com.hachly.casita.everyday"

    static func save(_ credential: SpaceCredential) throws {
        let data = try JSONEncoder().encode(credential)
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, nil
        ) else { throw StorageError.stretchFailed }
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecAttrAccessControl as String] = access
        add[kSecValueData as String] = data
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw StorageError.stretchFailed }
    }

    /// Reading the item is what shows the Face ID prompt.
    static func load() async throws -> SpaceCredential? {
        try await Task.detached {
            let context = LAContext()
            context.localizedReason = "Open your everyday space"
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecUseAuthenticationContext as String] = context
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
                return nil
            }
            return try JSONDecoder().decode(SpaceCredential.self, from: data)
        }.value
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppGroup.id,
        ]
    }
}
