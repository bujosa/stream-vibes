import ProjectDescription

let project = Project(
    name: "StreamVibes",
    targets: [
        .target(
            name: "StreamVibes",
            destinations: .macOS,
            product: .app,
            bundleId: "com.bujosa.streamvibes",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "StreamVibes",
                "CFBundleIconFile": "",
                "CFBundleIconName": "AppIcon",
                "NSMainNibFile": "",
            ]),
            sources: ["StreamVibes/Sources/**"],
            resources: ["StreamVibes/Resources/**"],
            entitlements: .file(path: "StreamVibes/StreamVibes.entitlements"),
            dependencies: [
                .external(name: "PostgresNIO"),
                .external(name: "NIOSSL"),
            ],
            settings: .settings(base: ["OTHER_LDFLAGS": ["$(inherited)", "-lc++"]])
        )
    ]
)
