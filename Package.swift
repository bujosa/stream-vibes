// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LocalSecurity",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LocalSecurity", path: "StreamVibes/Sources/Services/Privacy"),
        .target(name: "ModelConfiguration", path: "StreamVibes/Sources/Services/ModelConfiguration"),
        .testTarget(name: "LocalSecurityTests", dependencies: ["LocalSecurity", "ModelConfiguration"], path: "Tests/LocalSecurityTests"),
    ]
)
