import Foundation
import Security

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "钥匙串操作失败 (\(status)): \(message)"
    }
}

/// Thin wrapper over the login keychain for the single VPN password.
enum Keychain {
    static let service = "com.chengfei.xdvpn"
    static let account = "vpn-password"

    /// Service/account used by the original `xd-vpn` shell script, so an
    /// existing password can be imported without retyping it.
    static let legacyScriptService = "XD-VPN"

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Checks presence without touching the secret, so no ACL prompt is shown.
    static func exists(service: String = service, account: String = account) -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    static func read(service: String = service, account: String = account) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ password: String, service: String = service, account: String = account) throws {
        let data = Data(password.utf8)
        let query = baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "XD VPN"
            add[kSecAttrDescription as String] = "VPN password"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(service: String = service, account: String = account) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }
}
