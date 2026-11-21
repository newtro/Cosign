import Foundation
import Security

public enum KeychainHelper {
    private static var servicePrefix: String {
        Bundle.main.bundleIdentifier ?? "com.scottsmith.cosign"
    }

    public static func save(key: String, account: String) throws {
        let service = "\(servicePrefix).\(account)"
        let data = Data(key.utf8)
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "CosignKeychain", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain save failed (\(status))"
            ])
        }
    }

    public static func read(account: String) -> String? {
        let service = "\(servicePrefix).\(account)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let str = String(data: data, encoding: .utf8), !str.isEmpty {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    public static func delete(account: String) {
        let service = "\(servicePrefix).\(account)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
