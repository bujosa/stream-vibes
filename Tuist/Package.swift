// swift-tools-version: 5.10
import PackageDescription

#if TUIST
import struct ProjectDescription.PackageSettings

let packageSettings = PackageSettings(
    productTypes: [
        "Atomics": .framework,
        "NIOPosix": .staticFramework,
        "NIOSSL": .staticFramework,
        "NIOCore": .staticFramework,
        "NIOConcurrencyHelpers": .staticFramework,
        "NIOEmbedded": .staticFramework,
        "NIOTLS": .staticFramework,
        "NIOFoundationCompat": .staticFramework,
        "Crypto": .staticFramework,
        "CryptoExtras": .staticFramework,
        "CryptoBoringWrapper": .staticFramework,
        "CCryptoBoringSSLShims": .staticFramework,
        "CCryptoBoringSSL": .staticFramework,
        "_CryptoExtras": .staticFramework,
        "PostgresNIO": .staticFramework,
    ]
)
#endif

let package = Package(
    name: "StreamVibes",
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    ]
)
