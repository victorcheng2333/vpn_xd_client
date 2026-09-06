import Foundation
import Darwin
import VPNCore

/// Receives app diagnostics and sanitized helper/engine output, never credentials.
final class RollingActivityLog {
    enum Source: String, Codable { case app, physical, helper, recovery, lifecycle, quality }
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
        var schemaVersion: Int? = nil
        var build: String? = nil
        var osVersion: String? = nil
        var quality: QualityEvent? = nil
        var diagnostic: EngineDiagnostic? = nil
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
                connection: String, autoConnect: Bool, isError: Bool, quality: QualityEvent? = nil, diagnostic: EngineDiagnostic? = nil) {
        // Bound the message before capturing it on the asynchronous writer queue.
        let message = Self.safeMessage(message)
        queue.async {
            do {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let record = Record(timestamp: formatter.string(from: date), session: self.session, version: self.version,
                    source: source, event: event, stateBefore: state, connection: connection,
                    autoConnect: autoConnect, isError: isError, message: message, schemaVersion: 2,
                    build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development",
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString, quality: quality, diagnostic: diagnostic)
                var data = try JSONEncoder().encode(record)
                data.append(10)
                guard data.count <= self.maxBytes else { throw LogError.oversized }
                try self.write(data)
                self.report(failed: false)
            } catch { self.report(failed: true) }
        }
    }

    struct History {
        var events: [QualityEvent] = []
        var uncleanSession: String?
        var incomplete = false
    }

    /// Call before app.started is appended. Read on the same queue as rotation;
    /// reject special files and bound reads so diagnostics cannot block startup.
    func loadHistory(completion: @escaping (History) -> Void) {
        queue.async {
            var history = History()
            var last: Record?
            for index in (0..<self.fileCount).reversed() {
                do {
                    guard let data = try self.readFile(index) else { continue }
                    for line in data.split(separator: 10) {
                        guard let record = try? JSONDecoder().decode(Record.self, from: Data(line)) else {
                            history.incomplete = true; continue
                        }
                        last = record
                        if let event = record.quality { history.events.append(event) }
                    }
                } catch { history.incomplete = true }
            }
            // Missing shutdown evidence is not proof of a crash. On damaged
            // storage the previous session's outcome is unknown.
            if !history.incomplete, let last, last.event != "app.quitting" {
                history.uncleanSession = last.session
            }
            let result = history
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func readFile(_ index: Int) throws -> Data? {
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            if errno == ENOENT { return nil }
            throw LogError.invalidPath
        }
        defer { close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0, directoryInfo.st_uid == geteuid() else { throw LogError.invalidPath }
        let fd = openat(directoryFD, file(index).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw LogError.invalidPath
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size <= maxBytes else { throw LogError.invalidPath }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maxBytes {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw LogError.writeFailed }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw LogError.oversized
    }

    // Extra defense against accidentally passing common raw auth output in a
    // future caller. Engine output is also sanitized before leaving the helper.
    static func safeMessage(_ message: String) -> String {
        let pattern = #"(?i)(?:password|passwd|cookie|authorization|token|secret)[\s\"']*[:=]|bearer\s+|<\s*(?:password|token|cookie)\b|https?://[^\s/]+:[^\s/]+@"#
        if message.range(of: pattern, options: .regularExpression) != nil { return "[已省略含认证字段的诊断文本]" }
        let suffix = message.count > 2048 ? " [内容已截断，较长记录见助手日志]" : ""
        return String(message.prefix(2048 - suffix.count)).components(separatedBy: .controlCharacters).joined(separator: " ") + suffix
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
