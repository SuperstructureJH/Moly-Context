// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WeChatSyncMVP",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "wechat-sync", targets: ["WeChatSync"]),
    ],
    targets: [
        .executableTarget(
            name: "WeChatSync",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Vision"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
