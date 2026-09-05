import Foundation
import Security
import LocalAuthentication
import VPNCore

struct CredentialAccess {
    var contains: (String) -> Bool
    var read: (String) throws -> String
    var save: (String, String) throws -> Void
    var delete: (String) throws -> Void
    static let live = CredentialAccess(contains: KeychainStore.contains, read: KeychainStore.read,
                                       save: { try KeychainStore.save($0, account: $1) }, delete: KeychainStore.delete)
}

enum KeychainStore {
    private static let service = "com.xd.vpn.credentials"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func contains(_ account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
    static func read(_ account: String) throws -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw VPNError.unavailable(status == errSecItemNotFound ? "未找到已保存的密码，请在 VPN 配置中重新填写。" : "无法读取钥匙串密码，请允许 XD VPN 访问钥匙串后重试。")
        }
        return password
    }
    static func save(_ password: String, account: String) throws {
        try OpenConnect.validatePassword(password)
        let value = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query(account) as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account).merging(value) { _, new in new }
            q[kSecAttrLabel as String] = "XD VPN · VPN 密码"
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VPNError.system("密码未能存入钥匙串（\(status)）。请解锁登录钥匙串后重试。") }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VPNError.system("无法删除钥匙串中的密码（\(status)）。") }
    }
}
