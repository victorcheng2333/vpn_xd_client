// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "XDVPN",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "XDVPN",
            path: "Sources/XDVPN"
        )
    ]
)
