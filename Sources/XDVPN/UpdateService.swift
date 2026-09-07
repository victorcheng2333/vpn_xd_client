import Foundation
import CryptoKit
import VPNCore

/// Tokens are sent only to GitHub's API; asset CDN redirects never receive them.
final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var safe = request
        if request.url?.host != "api.github.com" { safe.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(safe)
    }
}

struct UpdateService {
    let repository: String
    let session: URLSession
    static let liveSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
    }()

    init(repository: String, session: URLSession = liveSession) {
        self.repository = repository; self.session = session
    }

    private func request(_ url: URL, token: String?, download: Bool = false) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(download ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("XDVPN-Updater", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ReleaseUpdateError.invalidRelease }
        switch http.statusCode {
        case 200: break
        case 401, 404: throw ReleaseUpdateError.accessDenied
        case 403, 429: throw ReleaseUpdateError.rateLimited
        default: throw ReleaseUpdateError.http(http.statusCode)
        }
    }

    func check(current: ReleaseVersion, architecture: String, token: String?) async throws -> ReleaseUpdate? {
        guard repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              !repository.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw ReleaseUpdateError.invalidConfiguration
        }
        let (data, response) = try await session.data(for: request(url, token: token))
        try Self.validateResponse(response)
        guard data.count <= 4 * 1024 * 1024 else { throw ReleaseUpdateError.invalidRelease }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return try release.update(current: current, repository: repository, architecture: architecture)
    }

    func download(_ update: ReleaseUpdate, token: String?, directory: URL) async throws -> URL {
        let (temporary, response) = try await session.download(for: request(update.asset.url, token: token, download: true))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.validateResponse(response)
        try Self.verify(temporary, size: update.asset.size, sha256: update.sha256)
        try Task.checkCancellation()
        // A unique directory avoids replacing an existing installer or following a preexisting symlink.
        let folder = directory.appendingPathComponent("XDVPN-\(update.version)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(update.asset.name)
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return destination
    }

    static func verify(_ file: URL, size: Int64, sha256: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            count += Int64(bytes.count)
            guard count <= size else { throw ReleaseUpdateError.checksum }
            hash.update(data: bytes)
        }
        guard count == size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw ReleaseUpdateError.checksum
        }
    }
}
