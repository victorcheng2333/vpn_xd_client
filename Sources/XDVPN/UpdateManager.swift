import SwiftUI
import AppKit
import Security
import VPNCore

@MainActor final class UpdateManager: ObservableObject {
    @Published var showPanel = false
    @Published private(set) var busy = false
    @Published private(set) var message = "检查 GitHub 上的正式版本。"
    @Published private(set) var available: ReleaseUpdate?
    @Published private(set) var downloaded: URL?
    @Published private(set) var hasToken = false
    let repository = Bundle.main.infoDictionary?["XDVPNReleaseRepository"] as? String ?? "victorcheng2333/vpn_xd_client"
    let channel = Bundle.main.infoDictionary?["XDVPNBuildChannel"] as? String ?? "development"
    var displayVersion: String {
        Bundle.main.infoDictionary?["XDVPNDisplayVersion"] as? String ?? "开发构建"
    }
    private var tokenAccount: String { "github-release:\(repository)" }
    private var lastCheckKey: String { "release-check:\(repository):\(displayVersion)" }
    private var service: UpdateService { UpdateService(repository: repository) }

    init() { hasToken = UpdateTokenStore.contains(account: tokenAccount) }

    func checkAutomatically() async {
        guard channel == "release", AppInstanceCoordinator.shared.isPrimary else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 24 * 60 * 60 else { return }
        await check(manual: false)
    }

    func check(manual: Bool = true) async {
        guard !busy else { return }
        if manual { showPanel = true }
        guard channel == "release" else {
            message = "当前为\(channel == "test" ? "测试" : "开发")版本（\(displayVersion)），不参与正式版更新。"
            return
        }
        busy = true; message = "正在检查更新…"
        defer { busy = false }
        do {
            guard let version = ReleaseVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") else {
                throw ReleaseUpdateError.invalidConfiguration
            }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let token = try UpdateTokenStore.read(account: tokenAccount)
            available = try await service.check(current: version, architecture: architecture, token: token)
            downloaded = nil
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            message = available.map { "发现正式版本 \($0.version)。" } ?? "当前已是最新正式版本（\(version)）。"
            if available != nil { showPanel = true }
        } catch {
            available = nil
            message = error.localizedDescription
        }
    }

    func download() async {
        guard !busy, let available else { return }
        busy = true; message = "正在下载并校验安装包…"
        defer { busy = false }
        do {
            let token = try UpdateTokenStore.read(account: tokenAccount)
            let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            downloaded = try await service.download(available, token: token, directory: directory)
            message = "SHA-256 校验通过。请断开 VPN 并退出旧版，再打开安装包替换应用。"
        } catch { message = error.localizedDescription }
    }

    func saveToken(_ token: String) {
        do {
            try UpdateTokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines), account: tokenAccount)
            hasToken = UpdateTokenStore.contains(account: tokenAccount)
            message = hasToken ? "Token 已保存在本机钥匙串，可重新检查更新。" : "已移除 Token。"
        } catch { message = error.localizedDescription }
    }
}

/// Isolated from VPN credentials; never included in a profile, bundle, URL, or log.
enum UpdateTokenStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.xd.vpn.updates",
         kSecAttrAccount as String: account]
    }
    static func contains(account: String) -> Bool {
        var q = query(account); q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    static func read(account: String) throws -> String? {
        var q = query(account); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw VPNError.system("无法读取更新 Token，请检查本机钥匙串。")
        }
        return token
    }
    static func save(_ token: String, account: String) throws {
        if token.isEmpty {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VPNError.system("无法删除更新 Token。") }
            return
        }
        guard token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw VPNError.system("Token 格式无效。") }
        let value = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query(account) as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account).merging(value) { _, new in new }
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VPNError.system("无法保存更新 Token。") }
    }
}
