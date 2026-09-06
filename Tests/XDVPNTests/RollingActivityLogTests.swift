import XCTest
import Darwin
@testable import XDVPN

final class RollingActivityLogTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("xdvpn-log-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func append(_ text: String, to log: RollingActivityLog) {
        log.append(text, date: Date(), source: .recovery, event: "reconnect.requested", state: "已安全连接",
                   connection: "fixture-attempt", autoConnect: true, isError: false)
    }
    private func records(_ file: URL) throws -> [RollingActivityLog.Record] {
        try Data(contentsOf: file).split(separator: 10).map { try JSONDecoder().decode(RollingActivityLog.Record.self, from: Data($0)) }
    }

    func testLogsSurviveNewWriterAndHavePrivatePermissionsAndDistinctSessions() throws {
        let log = RollingActivityLog(directory: folder)
        append("first launch", to: log); log.flush()
        let next = RollingActivityLog(directory: folder)
        append("second launch", to: next); next.flush()
        let file = folder.appendingPathComponent("activity.jsonl")
        let rows = try records(file)
        XCTAssertEqual(rows.map(\.message), ["first launch", "second launch"])
        XCTAssertNotEqual(rows[0].session, rows[1].session)
        XCTAssertEqual(rows[0].source, .recovery)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(formatter.date(from: rows[0].timestamp))
        for (url, permissions) in [(folder!, 0o700), (file, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, permissions)
        }
    }

    func testRotationKeepsNewestRecordsWithinFileAndByteLimits() throws {
        let unrelated = folder.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        let log = RollingActivityLog(directory: folder, maxBytes: 1024, fileCount: 3)
        for index in 0..<30 { append("event \(index)", to: log) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        XCTAssertEqual(files.count, 3)
        for file in files {
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 1024)
            XCTAssertFalse(try records(file).isEmpty)
        }
        XCTAssertEqual(try records(folder.appendingPathComponent("activity.jsonl")).last?.message, "event 29")
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
    }

    func testConcurrentAppendsRemainWholeJSONRecords() throws {
        let log = RollingActivityLog(directory: folder)
        DispatchQueue.concurrentPerform(iterations: 100) { index in self.append("event \(index)", to: log) }
        log.flush()
        let rows = try records(folder.appendingPathComponent("activity.jsonl"))
        XCTAssertEqual(rows.count, 100)
        XCTAssertEqual(Set(rows.map(\.message)).count, 100)
    }

    func testCommonAuthOutputIsOmittedAndControlCharactersCannotForgeLogLines() throws {
        let log = RollingActivityLog(directory: folder)
        for message in ["Cookie: webvpn=super-secret", "Authorization: Bearer super-secret", "password=super-secret",
                        #"{"token":"super-secret"}"#, "<password>super-secret</password>", "https://user:super-secret@example.invalid"] {
            append(message, to: log)
        }
        append("普通诊断\nforged line\tend", to: log)
        append(String(repeating: "大", count: 10_000), to: log)
        log.flush()
        let file = folder.appendingPathComponent("activity.jsonl")
        let data = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(data.contains("super-secret"))
        let rows = try records(file)
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(rows[6].message, "普通诊断 forged line end")
        XCTAssertEqual(rows[7].message.count, 2048)
        XCTAssertTrue(rows[7].message.contains("内容已截断"))
    }

    func testSymlinkAndHardlinkTargetsAreNeverWrittenAndFailureIsReported() throws {
        let target = folder.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        for hardlink in [false, true] {
            let directory = folder.appendingPathComponent(hardlink ? "hard" : "symbolic")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let current = directory.appendingPathComponent("activity.jsonl")
            if hardlink { try FileManager.default.linkItem(at: target, to: current) }
            else { try FileManager.default.createSymbolicLink(at: current, withDestinationURL: target) }
            let failed = expectation(description: "write rejected")
            let log = RollingActivityLog(directory: directory)
            log.onStatus = { available in XCTAssertFalse(available); failed.fulfill() }
            append("must not leak", to: log); log.flush()
            wait(for: [failed], timeout: 2)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "untouched")
        }
    }

    func testUnexpectedFIFOIsRejectedWithoutBlockingLoggerOrQuit() throws {
        let current = folder.appendingPathComponent("activity.jsonl")
        XCTAssertEqual(mkfifo(current.path, 0o600), 0)
        let log = RollingActivityLog(directory: folder)
        let failed = expectation(description: "FIFO rejected"), flushed = expectation(description: "quit can proceed")
        log.onStatus = { available in XCTAssertFalse(available); failed.fulfill() }
        append("fixture", to: log)
        log.flush { flushed.fulfill() }
        wait(for: [failed, flushed], timeout: 2)
    }

    func testHistoryReplaysQualityAndDistinguishesShutdownFromMissingExitEvidence() throws {
        let log = RollingActivityLog(directory: folder)
        let sample = QualityEvent(kind: .attemptSucceeded, connection: "attempt", durationMS: 1200)
        log.append("quality", date: Date(), source: .quality, event: "quality.attemptSucceeded", state: "connecting",
                   connection: "attempt", autoConnect: false, isError: false, quality: sample)
        log.flush()
        let missing = expectation(description: "missing exit")
        log.loadHistory { history in
            XCTAssertEqual(history.events, [sample]); XCTAssertNotNil(history.uncleanSession)
            XCTAssertFalse(history.incomplete); missing.fulfill()
        }
        wait(for: [missing], timeout: 2)
        log.append("quit", date: Date(), source: .lifecycle, event: "app.quitting", state: "idle",
                   connection: "attempt", autoConnect: false, isError: false)
        let clean = expectation(description: "normal exit")
        log.loadHistory { history in
            XCTAssertEqual(history.events, [sample]); XCTAssertNil(history.uncleanSession); clean.fulfill()
        }
        wait(for: [clean], timeout: 2)
    }

    func testHistoryKeepsLegacyRowsAndValidRowsBesideTruncatedTailWithoutClaimingCrash() throws {
        let log = RollingActivityLog(directory: folder)
        append("legacy", to: log); log.flush()
        let file = folder.appendingPathComponent("activity.jsonl")
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for key in ["schemaVersion", "build", "osVersion", "quality"] { row.removeValue(forKey: key) }
        var data = try JSONSerialization.data(withJSONObject: row)
        data.append(contentsOf: "\n{\"truncated\":".utf8)
        try data.write(to: file)
        let read = expectation(description: "partial history")
        log.loadHistory { history in
            XCTAssertTrue(history.incomplete); XCTAssertNil(history.uncleanSession)
            XCTAssertTrue(history.events.isEmpty); read.fulfill()
        }
        wait(for: [read], timeout: 2)
    }

    func testHistoryRejectsSpecialFilesWithoutBlocking() throws {
        XCTAssertEqual(mkfifo(folder.appendingPathComponent("activity.jsonl").path, 0o600), 0)
        let log = RollingActivityLog(directory: folder)
        let read = expectation(description: "FIFO not read")
        log.loadHistory { history in
            XCTAssertTrue(history.incomplete); XCTAssertNil(history.uncleanSession); read.fulfill()
        }
        wait(for: [read], timeout: 2)
    }
}
