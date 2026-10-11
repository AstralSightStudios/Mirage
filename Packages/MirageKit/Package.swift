// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MirageKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MirageKit", targets: ["MirageKit"]),
        .executable(name: "miragectl", targets: ["miragectl"]),
    ],
    targets: [
        .target(
            name: "CLittleFS",
            exclude: ["LICENSE.md"],
            cSettings: [
                .define("LFS_MULTIVERSION"),
                .define("LFS_NO_DEBUG"),
                .define("LFS_NO_WARN"),
            ]
        ),
        .target(
            name: "MirageKit",
            dependencies: ["CLittleFS"],
            resources: [.copy("Resources/BindTemplate")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "miragectl",
            dependencies: ["MirageKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MirageKitTests",
            dependencies: ["MirageKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
