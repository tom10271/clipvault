// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipVault",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ClipVault", targets: ["ClipVault"])],
    targets: [
        .target(name: "ClipVaultCore"),
        .executableTarget(name: "ClipVault", dependencies: ["ClipVaultCore"]),
        .testTarget(name: "ClipVaultCoreTests", dependencies: ["ClipVaultCore"])
    ]
)
