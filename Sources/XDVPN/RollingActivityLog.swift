import Foundation
import Darwin

/// Receives app diagnostics and the helper's already-normalized events only.
/// There is no connection to OpenConnect's raw stdout/stderr or credentials.
final class RollingActivityLog {
    enum Source: String, Codable { case app, physical, helper, recovery, lifecycle }
    struct Record: Codable {
        let timestamp: String
        let session: String
        let version: String
        let source: Source
        let event: String
        let stateBefore: String
        let connection: String
        let autoConnect: Bool
        let isError: Bool
        let message: String
    }

    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/XD VPN", isDirectory: true)
    let directory: URL
    private let queue = DispatchQueue(label: "com.xd.vpn.activity-log", qos: .utility)
    private let session = UUID().uuidString
    private let version: String
    private let maxBytes: Int
    private let fileCount: Int
    private var reportedFailure: Bool?
    // Set before the first append. Callbacks run on the main queue.
    var onStatus: ((Bool) -> Void)?

    init(directory: URL = defaultDirectory, maxBytes: Int = 1_048_576, fileCount: Int = 4,
         version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development") {
        precondition(maxBytes >= 1024 && fileCount >= 1)
        self.directory = directory; self.maxBytes = maxBytes; self.fileCount = fileCount; self.version = version
    }

    func append(_ message: String, date: Date, source: Source, event: String, state: String,
                connection: String, autoConnect: Bool, isError: Bool) {
        // Bound the message before capturing it on the asynchronous writer queue.
        let message = Self.safeMessage(message)
        queue.async {
            do {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let record = Record(timestamp: formatter.string(from: date), session: self.session, version: self.version,
                    source: source, event: event, stateBefore: state, connection: connection,
                    autoConnect: autoConnect, isError: isError, message: message)
                var data = try JSONEncoder().encode(record)
                data.append(10)
                guard data.count <= self.maxBytes else { throw LogError.oversized }
                try self.write(data)
                self.report(failed: false)
            } catch { self.report(failed: true) }
        }
    }

    // Extra defense against accidentally passing common raw auth output in a
    // future caller. The primary boundary remains normalized messages at source.
    static func safeMessage(_ message: String) -> String {
        let pattern = #"(?i)(?:password|passwd|cookie|authorization|token|secret)[\s\"']*[:=]|bearer\s+|<\s*(?:password|token|cookie)\b|https?://[^\s/]+:[^\s/]+@"#
        if message.range(of: pattern, options: .regularExpression) != nil { return "[已省略含认证字段的诊断文本]" }
        return String(message.prefix(2048)).components(separatedBy: .controlCharacters).joined(separator: " ")
    }

    private enum LogError: Error { case invalidPath, writeFailed, oversized }

    private func file(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "activity.jsonl" : "activity.\(index).jsonl")
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LogError.invalidPath }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), fchmod(fd, 0o700) == 0 else { throw LogError.invalidPath }
    }

    private func openCurrent() throws -> (Int32, Int) {
        // NONBLOCK prevents a misplaced FIFO from hanging the writer before
        // fstat can reject it. It has no effect on normal regular log files.
        let fd = open(file(0).path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw LogError.invalidPath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, fchmod(fd, 0o600) == 0 else { close(fd); throw LogError.invalidPath }
        return (fd, Int(info.st_size))
    }

    private func write(_ data: Data) throws {
        try prepareDirectory()
        var (fd, size) = try openCurrent()
        defer { if fd >= 0 { close(fd) } }
        if size + data.count > maxBytes {
            close(fd); fd = -1
            // Fixed filenames only. Never enumerate/delete unrelated files.
            if unlink(file(fileCount - 1).path) != 0 && errno != ENOENT { throw LogError.writeFailed }
            if fileCount > 1 {
                for index in stride(from: fileCount - 2, through: 0, by: -1) {
                    if rename(file(index).path, file(index + 1).path) != 0 && errno != ENOENT { throw LogError.writeFailed }
                }
            }
            (fd, size) = try openCurrent()
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw LogError.writeFailed }
                offset += written
            }
        }
    }

    private func report(failed: Bool) {
        guard reportedFailure != failed else { return }
        reportedFailure = failed
        let callback = onStatus
        DispatchQueue.main.async { callback?(!failed) }
    }

    func flush() { queue.sync {} }
    func flush(completion: @escaping () -> Void) {
        // Only the main queue accesses finished. Slow/unavailable storage must
        // not prevent quitting; normal exits still drain all queued records.
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true; completion()
        }
        queue.async { DispatchQueue.main.async(execute: finish) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: finish)
    }
}
