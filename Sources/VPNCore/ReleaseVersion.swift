import Foundation

/// Stable versions deliberately exclude dev/test/prerelease suffixes.
public struct ReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public var description: String { "\(major).\(minor).\(patch)" }

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0" else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let url: URL
        public let size: Int64
        public let digest: String?
        public let state: String
    }
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let html_url: URL
    public let assets: [Asset]

    public func update(current: ReleaseVersion, repository: String, architecture: String) throws -> ReleaseUpdate? {
        guard !draft, !prerelease, tag_name.hasPrefix("v"),
              let version = ReleaseVersion(String(tag_name.dropFirst())) else { return nil }
        guard version > current else { return nil }
        guard architecture == "arm64" || architecture == "x86_64" else { throw ReleaseUpdateError.invalidRelease }
        guard html_url.absoluteString == "https://github.com/\(repository)/releases/tag/\(tag_name)" else {
            throw ReleaseUpdateError.invalidRelease
        }
        let name = "XD-VPN-\(version)-macOS-\(architecture).dmg"
        let matches = assets.filter { $0.name == name }
        guard matches.count == 1, let asset = matches.first,
              asset.state == "uploaded", asset.size > 0, asset.size <= 1_073_741_824,
              let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw ReleaseUpdateError.invalidRelease
        }
        let sha256 = String(digest.dropFirst(7))
        let prefix = "https://api.github.com/repos/\(repository)/releases/assets/"
        guard sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              asset.url.absoluteString.hasPrefix(prefix) else { throw ReleaseUpdateError.invalidRelease }
        let assetID = asset.url.absoluteString.dropFirst(prefix.count)
        guard !assetID.isEmpty, assetID.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw ReleaseUpdateError.invalidRelease
        }
        return ReleaseUpdate(version: version, pageURL: html_url, asset: asset, sha256: sha256)
    }
}

public struct ReleaseUpdate: Sendable {
    public let version: ReleaseVersion
    public let pageURL: URL
    public let asset: GitHubRelease.Asset
    public let sha256: String
}

public enum ReleaseUpdateError: LocalizedError {
    case invalidRelease, accessDenied, rateLimited, http(Int), checksum, invalidConfiguration
    public var errorDescription: String? {
        switch self {
        case .invalidRelease: return "发布信息不完整或不可信：需要对应芯片的 DMG 和 GitHub SHA-256 摘要。"
        case .accessDenied: return "未找到可访问的正式版本。私有仓库请设置具有 Contents 只读权限的 GitHub Token，并确认仓库已有正式 Release。"
        case .rateLimited: return "GitHub 请求次数受限或访问被拒绝，请检查 Token 权限或稍后重试。"
        case .http(let code): return "更新服务请求失败（HTTP \(code)），请稍后重试。"
        case .checksum: return "安装包大小或 SHA-256 校验失败，已丢弃下载文件，请重新检查更新。"
        case .invalidConfiguration: return "当前应用的版本或发布仓库配置无效，请使用完整安装包。"
        }
    }
}
