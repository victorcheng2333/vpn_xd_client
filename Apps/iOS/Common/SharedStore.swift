import Foundation

/// Only nonsecret state. Extension serial queue is the writer during a session;
/// App resets recovery policy only after its own tunnel is fully disconnected.
struct SharedStore {
    private var directory: URL {
        get throws {
            guard let value = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: RuntimeConfiguration.appGroup) else {
                throw ConfigurationError.invalid("App Group 不可用，请检查 App 和 Extension 签名配置。")
            }
            return value
        }
    }
    func read<T: Decodable>(_ type: T.Type, name: String, fallback: T) throws -> T {
        let url = try directory.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    func write<T: Encodable>(_ value: T, name: String) throws {
        let url = try directory.appendingPathComponent(name + ".json")
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
