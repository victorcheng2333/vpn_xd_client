import Foundation
import Darwin

public struct EngineDiagnostic: Codable, Equatable {
    public enum Source: String, Codable { case openconnect, script, route, helper }
    public enum Level: String, Codable { case info, warning, error }
    public var source: Source
    public var code: String
    public var phase: String
    public var processID: Int32?
    public var errorNumber: Int32?
    public var level: Level
    public init(source: Source, code: String, phase: String, processID: Int32? = nil,
                errorNumber: Int32? = nil, level: Level = .info) {
        self.source = source; self.code = code; self.phase = phase; self.processID = processID
        self.errorNumber = errorNumber; self.level = level
    }

    public static func classify(_ line: String, phase: String, processID: Int32) -> Self {
        let text = line.lowercased()
        let errors: [(String, Int32, [String])] = [
            ("transport.addressUnavailable", EADDRNOTAVAIL, ["can't assign requested address", "cannot assign requested address"]),
            ("transport.networkUnreachable", ENETUNREACH, ["network is unreachable"]),
            ("transport.hostUnreachable", EHOSTUNREACH, ["no route to host"]),
            ("transport.refused", ECONNREFUSED, ["connection refused"]),
            ("transport.timeout", ETIMEDOUT, ["connection timed out"])
        ]
        for (code, number, patterns) in errors where patterns.contains(where: text.contains) {
            return .init(source: .openconnect, code: code, phase: phase, processID: processID,
                         errorNumber: number, level: .error)
        }
        let failed = ["failed", "error", "bad address", "file exists", "not in table", "timed out"].contains(where: text.contains)
        return .init(source: text.hasPrefix("xdvpn hook") ? .script : .openconnect,
                     code: text.hasPrefix("xdvpn hook") ? "script.lifecycle" : (failed ? "engine.error" : "engine.output"),
                     phase: phase, processID: processID, level: failed ? .error : .info)
    }
}

/// Keep an entry for every line, including unfamiliar errors and redactions.
/// Do not enable HTTP dumps: authentication bodies have no diagnostic value here.
struct DiagnosticSanitizer {
    var secrets: [String] = []
    private var inBody = false
    init(secrets: [String] = []) { self.secrets = secrets }
    mutating func sanitize(_ input: String) -> String {
        var text = String(input.prefix(8192))
        let lower = text.lowercased()
        if ["xdvpn ", "failed to ", "cstp ", "dtls ", "ssl ", "configured as "].contains(where: lower.hasPrefix) { inBody = false }
        if lower.contains("<?xml") || lower.contains("<html") || lower.contains("<auth") || lower.contains("<config-auth") { inBody = true }
        let bodyLine = inBody || text.trimmingCharacters(in: .whitespaces).hasPrefix("<")
        if lower.contains("</html>") || lower.contains("</auth>") || lower.contains("</config-auth>") { inBody = false }
        if bodyLine { return "[认证或服务端标记正文已脱敏]" }
        for secret in secrets where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "[redacted]")
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), encoded != secret {
                text = text.replacingOccurrences(of: encoded, with: "[redacted]")
            }
        }
        // Preserve the existence and category of sensitive lines, never their values.
        if text.range(of: #"(?i)(?:password|passwd|cookie|authorization|token|secret|session[_-]?id)[\s\"']*[:=]|bearer\s+|https?://[^\s/]+:[^\s/]+@"#,
                      options: .regularExpression) != nil { return "[含认证字段的输出已脱敏]" }
        text = text.replacingOccurrences(of: #"(https?://[^\s?#]+)[?#][^\s]*"#, with: "$1?[redacted]", options: .regularExpression)
        return text.components(separatedBy: .controlCharacters).joined(separator: " ") + (input.count > 8192 ? " [超过 8192 字符，已截断]" : "")
    }
}

/// The privileged process keeps its own copy even after the app/socket exits.
/// Only a fixed root-owned directory is used; no user-selected paths in production.
public final class HelperDiagnosticLog {
    public let directory: String
    private let owner: uid_t
    private let maxBytes: Int
    private let fileCount: Int
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private let session = UUID().uuidString
    public convenience init(userID: uid_t) {
        self.init(directory: "/Library/Logs/XD VPN/helper-\(userID)", owner: 0)
    }
    init(directory: String, owner: uid_t, maxBytes: Int = 4_194_304, fileCount: Int = 4) {
        self.directory = directory; self.owner = owner; self.maxBytes = maxBytes; self.fileCount = fileCount
    }
    private struct Record: Codable {
        let timestamp: String
        let helperVersion: String
        let session: String
        let sequence: UInt64
        let event: HelperEvent
    }
    public func append(_ event: HelperEvent) throws {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try JSONEncoder().encode(Record(timestamp: formatter.string(from: Date()), helperVersion: PrivilegePolicy.version,
                                                   session: session, sequence: sequence, event: event))
        data.append(10)
        guard data.count <= maxBytes else { throw POSIXError(.EFBIG) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Validate every component beneath the trusted log parent before opening.
        var path = directory
        while path != "/" {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == owner || (owner != 0 && info.st_uid == 0),
                  (path == "/private/tmp" || info.st_mode & 0o022 == 0) else { throw POSIXError(.EPERM) }
            path = (path as NSString).deletingLastPathComponent
        }
        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw POSIXError(.EIO) }
        defer { close(directoryFD) }
        guard fchmod(directoryFD, 0o700) == 0 else { throw POSIXError(.EPERM) }
        func name(_ index: Int) -> String { index == 0 ? "helper.jsonl" : "helper.\(index).jsonl" }
        func openFile() throws -> (Int32, Int) {
            let fd = openat(directoryFD, name(0), O_CREAT | O_APPEND | O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_nlink == 1,
                  info.st_mode & S_IFMT == S_IFREG, fchmod(fd, 0o600) == 0 else { close(fd); throw POSIXError(.EPERM) }
            return (fd, Int(info.st_size))
        }
        var (fd, size) = try openFile()
        defer { if fd >= 0 { close(fd) } }
        if size + data.count > maxBytes {
            close(fd); fd = -1
            if unlinkat(directoryFD, name(fileCount - 1), 0) != 0 && errno != ENOENT { throw POSIXError(.EIO) }
            if fileCount > 1 {
                for index in stride(from: fileCount - 2, through: 0, by: -1) {
                    if renameat(directoryFD, name(index), directoryFD, name(index + 1)) != 0 && errno != ENOENT { throw POSIXError(.EIO) }
                }
            }
            (fd, size) = try openFile()
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        if event.kind == .stopped || event.kind == .failure || event.diagnostic?.level == .error {
            guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        }
    }
}
