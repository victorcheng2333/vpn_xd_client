import XCTest
import CryptoKit
import VPNCore
@testable import XDVPN

final class ReleaseUpdateTests: XCTestCase {
    private let repo = "owner/repo"
    private func payload(tag: String = "v1.2.0", draft: Bool = false, prerelease: Bool = false,
                         name: String = "XD-VPN-1.2.0-macOS-arm64.dmg", digest: String? = "sha256:" + String(repeating: "a", count: 64),
                         url: String = "https://api.github.com/repos/owner/repo/releases/assets/42",
                         page: String? = nil) throws -> Data {
        var asset: [String: Any] = ["name": name, "url": url, "size": 5, "state": "uploaded"]
        if let digest { asset["digest"] = digest }
        return try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease,
            "html_url": page ?? "https://github.com/owner/repo/releases/tag/\(tag)", "assets": [asset]])
    }
    private func update(_ data: Data, current: String = "1.1.19") throws -> ReleaseUpdate? {
        try JSONDecoder().decode(GitHubRelease.self, from: data).update(current: ReleaseVersion(current)!, repository: repo, architecture: "arm64")
    }

    func testNumericComparisonAndStrictStableVersionParsing() {
        XCTAssertGreaterThan(ReleaseVersion("1.10.0")!, ReleaseVersion("1.9.99")!)
        XCTAssertGreaterThan(ReleaseVersion("2.0.0")!, ReleaseVersion("1.99.99")!)
        XCTAssertEqual(ReleaseVersion("1.2.3")?.description, "1.2.3")
        for value in ["1.2", "1.2.3.4", "01.2.3", "1.02.3", "-1.2.3", "1.2.3-test.9", "1.2.3+build.2", "１.2.3", "1.2.3\n", "99999999999999999999999.0.0"] {
            XCTAssertNil(ReleaseVersion(value), value)
        }
    }

    func testOnlyNewStableReleasesAreEligible() throws {
        XCTAssertEqual(try update(payload())?.version, ReleaseVersion("1.2.0"))
        XCTAssertNil(try update(payload(), current: "1.2.0"))
        XCTAssertNil(try update(payload(), current: "2.0.0"))
        XCTAssertNil(try update(payload(draft: true)))
        XCTAssertNil(try update(payload(prerelease: true)))
        XCTAssertNil(try update(payload(tag: "v1.2.0-test.99")))
        XCTAssertNil(try update(payload(tag: "1.2.0")))
    }

    func testRejectMissingChecksumWrongArchitectureAndUntrustedURLs() throws {
        XCTAssertThrowsError(try update(payload(digest: nil)))
        XCTAssertThrowsError(try update(payload(digest: "sha256:bad")))
        XCTAssertThrowsError(try update(payload(name: "XD-VPN-1.2.0-macOS-x86_64.dmg")))
        for url in ["http://api.github.com/repos/owner/repo/releases/assets/42", "https://evil.example/42",
                    "https://api.github.com/repos/other/repo/releases/assets/42", "https://api.github.com/repos/owner/repo/releases/assets/42?token=secret"] {
            XCTAssertThrowsError(try update(payload(url: url)))
        }
        XCTAssertThrowsError(try update(payload(page: "https://github.com/other/repo/releases/tag/v1.2.0")))
    }

    func testDownloadedBytesMustMatchSizeAndSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data("hello".utf8)
        try bytes.write(to: file)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try UpdateService.verify(file, size: 5, sha256: sha))
        XCTAssertThrowsError(try UpdateService.verify(file, size: 6, sha256: sha))
        XCTAssertThrowsError(try UpdateService.verify(file, size: 4, sha256: sha))
        XCTAssertThrowsError(try UpdateService.verify(file, size: 5, sha256: String(repeating: "0", count: 64)))
    }

    func testPrivateRepositoryErrorsAreNotReportedAsUpToDate() throws {
        for status in [401, 403, 404, 429, 500] {
            let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try UpdateService.validateResponse(response))
        }
    }

    func testCheckSendsTokenOnlyInAuthorizationHeader() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateMockProtocol.self]
        let body = try payload()
        UpdateMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/owner/repo/releases/latest")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, body)
        }
        defer { UpdateMockProtocol.handler = nil }
        let service = UpdateService(repository: repo, session: URLSession(configuration: config))
        let result = try await service.check(current: ReleaseVersion("1.1.19")!, architecture: "arm64", token: "test-token")
        XCTAssertEqual(result?.version, ReleaseVersion("1.2.0"))
    }

    func testCDNRedirectStripsTokenAndRejectsHTTP() {
        let delegate = UpdateRedirectPolicy()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://api.github.com")!)
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for scheme in ["https", "http"] {
            var request = URLRequest(url: URL(string: "\(scheme)://release-assets.githubusercontent.com/file")!)
            request.setValue("Bearer private-token", forHTTPHeaderField: "Authorization")
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { safe in
                if scheme == "http" { XCTAssertNil(safe) }
                else { XCTAssertNotNil(safe); XCTAssertNil(safe?.value(forHTTPHeaderField: "Authorization")) }
            }
        }
        session.invalidateAndCancel()
    }
}

private final class UpdateMockProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
