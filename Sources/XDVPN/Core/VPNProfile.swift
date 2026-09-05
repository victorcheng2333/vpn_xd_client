import Foundation

/// The single VPN profile this app manages. The password lives in the keychain.
struct VPNProfile: Codable, Equatable {
    var server: String = "vpn.xindong.com:8443"
    var username: String = ""
    /// Optional `--servercert` value (e.g. `pin-sha256:...`) for servers whose
    /// certificate is not trusted by the system.
    var serverCertPin: String = ""

    var isComplete: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Host without the port, for display.
    var host: String {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.lastIndex(of: ":") { return String(trimmed[..<colon]) }
        return trimmed
    }

    private static let defaultsKey = "vpnProfile"

    static func load(from defaults: UserDefaults) -> VPNProfile {
        guard let data = defaults.data(forKey: defaultsKey),
              let profile = try? JSONDecoder().decode(VPNProfile.self, from: data)
        else { return VPNProfile() }
        return profile
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
