import XCTest
@testable import VPNCore

final class ServiceRuntimeTests: XCTestCase {
    private var root: URL!
    private var source: URL { root.appendingPathComponent("Source.app") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: source.appendingPathComponent("engine"))
        chmod(source.appendingPathComponent("engine").path, 0o777)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testSourceReplacementDoesNotChangePrivateExecutable() throws {
        let copy = try PrivateRuntimeCopy(source: source, parent: root, owner: geteuid())
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: source.appendingPathComponent("engine"))
        XCTAssertEqual(try String(contentsOf: copy.app.appendingPathComponent("engine")), "original")
        for path in [copy.directory, copy.app, copy.app.appendingPathComponent("engine")] {
            var info = stat()
            XCTAssertEqual(lstat(path.path, &info), 0)
            XCTAssertEqual(info.st_uid, geteuid())
            XCTAssertEqual(info.st_mode & 0o7777, 0o700)
        }
    }

    func testSymbolicLinksAreRejectedWithoutChangingTheirTargets() throws {
        let target = root.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        chmod(target.path, 0o644)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: target)
        XCTAssertThrowsError(try PrivateRuntimeCopy(source: source, parent: root, owner: geteuid()))
        XCTAssertEqual(try String(contentsOf: target), "untouched")
        var info = stat(); XCTAssertEqual(lstat(target.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o644)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("com.xd.vpn.runtime.") })
    }

    func testWritableOrSymlinkParentIsRejected() throws {
        chmod(root.path, 0o777)
        XCTAssertThrowsError(try PrivateRuntimeCopy(source: source, parent: root, owner: geteuid()))
        chmod(root.path, 0o700)
        let link = root.appendingPathComponent("parent-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try PrivateRuntimeCopy(source: source, parent: link, owner: geteuid()))
    }

    func testPrivateCopyLifetimeAndExplicitShutdownCleanup() throws {
        var copy: PrivateRuntimeCopy? = try PrivateRuntimeCopy(source: source, parent: root, owner: geteuid())
        let path = try XCTUnwrap(copy).directory.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        copy = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let another = try PrivateRuntimeCopy(source: source, parent: root, owner: geteuid())
        another.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: another.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testProtectedStorageWorksWithoutPrivateVarRunPermissions() throws {
        let run = root.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
        chmod(run.path, 0o775) // The actual macOS root:daemon runtime-directory mode.
        XCTAssertThrowsError(try PrivateRuntimeCopy(source: source, parent: run, owner: geteuid()))
        let storage = try RuntimeStorage.prepare(root: root, owner: geteuid())
        XCTAssertEqual(storage.path, root.appendingPathComponent("PrivilegedHelperTools/com.xd.vpn.runtime").path)
        let copy = try PrivateRuntimeCopy(source: source, parent: storage, owner: geteuid())
        XCTAssertEqual(try String(contentsOf: copy.app.appendingPathComponent("engine")), "original")
        var info = stat(); XCTAssertEqual(lstat(storage.path, &info), 0)
        XCTAssertEqual(info.st_uid, geteuid())
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(try RuntimeStorage.prepare(root: root, owner: geteuid()), storage)
    }

    func testStorageRejectsUnsafeAncestorAndSymlinkWithoutChangingIt() throws {
        chmod(root.path, 0o775)
        XCTAssertThrowsError(try RuntimeStorage.prepare(root: root, owner: geteuid()))
        chmod(root.path, 0o700)
        let shared = root.appendingPathComponent("PrivilegedHelperTools")
        try FileManager.default.createSymbolicLink(at: shared, withDestinationURL: source)
        XCTAssertThrowsError(try RuntimeStorage.prepare(root: root, owner: geteuid()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("com.xd.vpn.runtime").path))
    }

    func testStorageRejectsAnExistingPublicRuntimeDirectory() throws {
        let storage = try RuntimeStorage.prepare(root: root, owner: geteuid())
        chmod(storage.path, 0o755)
        XCTAssertThrowsError(try RuntimeStorage.prepare(root: root, owner: geteuid()))
        var info = stat(); XCTAssertEqual(lstat(storage.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o755, "Do not silently change an unexpected existing directory")
    }

    func testProductionStorageAnchorIsActuallyRootOwnedAndProtected() {
        var info = stat()
        XCTAssertEqual(lstat(RuntimeStorage.systemRoot.path, &info), 0)
        XCTAssertEqual(info.st_uid, 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(info.st_mode & 0o022, 0)
    }
}
