import Foundation
import Security

enum KeychainStore {
    static func save(_ password: String) throws -> Data {
        guard !password.isEmpty, password.utf8.count <= 4096 else { throw ConfigurationError.invalid("请填写密码（最多 4096 字节）。") }
        // A new immutable item per saved config preserves the old profile if saving NE preferences fails.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "XDVPN.iOS.password", kSecAttrAccount as String: UUID().uuidString,
            kSecAttrAccessGroup as String: RuntimeConfiguration.keychainGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(password.utf8), kSecReturnPersistentRef as String: true]
        var result: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &result)
        guard status == errSecSuccess, let reference = result as? Data else { throw error(status) }
        return reference
    }
    static func read(_ reference: Data) throws -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: reference, kSecReturnData as String: true] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw error(status) }
        return value
    }
    static func delete(_ reference: Data) { SecItemDelete([kSecValuePersistentRef as String: reference] as CFDictionary) }
    static func error(_ status: OSStatus) -> Error {
        ConfigurationError.invalid(status == errSecInteractionNotAllowed ? "凭据当前不可读取，请先解锁设备。" : "钥匙串操作失败（\(status)），请检查签名与共享权限。")
    }
}

enum RuntimeConfiguration {
    static var appGroup: String { Bundle.main.object(forInfoDictionaryKey: "SharedAppGroup") as? String ?? "" }
    static var keychainGroup: String { Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String ?? "" }
    static var providerID: String { Bundle.main.object(forInfoDictionaryKey: "TunnelProviderID") as? String ?? "" }
}
