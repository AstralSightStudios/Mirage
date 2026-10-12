// swift-tools-version: 6.0
// The SwiftCrossUI front-end of Mirage for Windows and Linux (GtkBackend; it
// also runs on macOS to preview that UI). The shipped macOS app is the SwiftUI
// one in Mirage.xcodeproj. Both compile the same models from App/Model.
import PackageDescription

let root = Context.packageDirectory
let companionCoreLib = "\(root)/AstroBoxBridge/target/release"

let package = Package(
    name: "MirageCross",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Mirage", targets: ["MirageCross"]),
    ],
    dependencies: [
        .package(path: "Packages/MirageKit"),
        .package(url: "https://github.com/moreSwift/swift-cross-ui",
                 revision: "0f3ec3958b79cdc39a1a3e604516b71ab33a9043"),
    ],
    targets: [
        .systemLibrary(name: "CMirageAstroBox", path: "CrossApp/CMirageAstroBox"),
        .executableTarget(
            name: "MirageCross",
            dependencies: [
                .product(name: "MirageKit", package: "MirageKit"),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "GtkBackend", package: "swift-cross-ui"),
                "CMirageAstroBox",
            ],
            path: ".",
            exclude: [
                "External", "AstroBoxBridge", "Packages", "Scripts", "Mirage.xcodeproj",
                "App/Views", "App/Resources", "App/MirageApp.swift", "CrossApp/CMirageAstroBox",
                "README.md", "project.yml", "LICENSE",
            ],
            sources: ["CrossApp/Sources", "App/Model"],
            swiftSettings: [
                .define("MIRAGE_ASTROBOX"),
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", companionCoreLib]),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("IOBluetooth", .when(platforms: [.macOS])),
                .linkedFramework("CoreBluetooth", .when(platforms: [.macOS])),
                .linkedFramework("WebKit", .when(platforms: [.macOS])),
                .linkedFramework("ApplicationServices", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
                .linkedFramework("CoreVideo", .when(platforms: [.macOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedLibrary("iconv", .when(platforms: [.macOS])),
            ]
        ),
    ]
)
