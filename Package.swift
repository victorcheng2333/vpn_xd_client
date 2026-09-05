// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XDVPN",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "XDVPN", targets: ["XDVPN"]),
        .executable(name: "XDVPNHelper", targets: ["XDVPNHelper"])
    ],
    targets: [
        .target(name: "VPNCore"),
        .executableTarget(name: "XDVPN", dependencies: ["VPNCore"]),
        .executableTarget(name: "XDVPNHelper", dependencies: ["VPNCore"]),
        .testTarget(name: "VPNCoreTests", dependencies: ["VPNCore"]),
        .testTarget(name: "XDVPNTests", dependencies: ["XDVPN", "VPNCore"])
    ],
    swiftLanguageModes: [.v5]
)
