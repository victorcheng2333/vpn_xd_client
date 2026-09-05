import Foundation

/// One foreground `sudo -n xd-vpn-helper connect …` process. Lines from
/// stdout/stderr are delivered as they arrive; `onExit` fires once both
/// pipes hit EOF and the process has terminated.
final class OpenConnectSession {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var buffers: [Int: Data] = [0: Data(), 1: Data()]

    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { process.isRunning }
    var sudoPID: Int32 { process.processIdentifier }

    func start(server: String, user: String, password: String, serverCertPin: String) throws {
        var helperArguments = ["connect", server, user]
        let pin = serverCertPin.trimmingCharacters(in: .whitespaces)
        if !pin.isEmpty { helperArguments.append(pin) }
        let cmd = PrivilegedHelper.command(helperArguments)
        process.executableURL = URL(fileURLWithPath: cmd.executable)
        process.arguments = cmd.arguments
        // Force English output so status parsing is stable regardless of the user's locale.
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "LANG": "C",
        ]
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("XDVPN_") {
            environment[key] = value
        }
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        group.enter() // process termination
        process.terminationHandler = { [group] _ in group.leave() }

        try process.run()

        pump(stdoutPipe.fileHandleForReading, key: 0)
        pump(stderrPipe.fileHandleForReading, key: 1)

        group.notify(queue: .global()) { [self] in
            onExit?(process.terminationStatus)
        }

        // openconnect reads exactly one line for --passwd-on-stdin.
        let writer = stdinPipe.fileHandleForWriting
        writer.write(Data((password + "\n").utf8))
        try? writer.close()
    }

    private func pump(_ handle: FileHandle, key: Int) {
        group.enter()
        Thread.detachNewThread { [self] in
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                consume(data, key: key)
            }
            flush(key: key)
            group.leave()
        }
    }

    private func consume(_ data: Data, key: Int) {
        var lines: [String] = []
        lock.lock()
        buffers[key, default: Data()].append(data)
        var buffer = buffers[key] ?? Data()
        while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer = buffer[buffer.index(after: newline)...]
        }
        buffers[key] = Data(buffer)
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    private func flush(key: Int) {
        lock.lock()
        let rest = buffers[key] ?? Data()
        buffers[key] = Data()
        lock.unlock()
        if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
    }
}
