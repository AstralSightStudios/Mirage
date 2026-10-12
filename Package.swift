// swift-tools-version: 6.0
// The SwiftCrossUI front-end of Mirage for Windows (WinUIBackend) and Linux
// (GtkBackend; the GTK build also runs on macOS to preview the UI). The shipped
// macOS app is the SwiftUI one in Mirage.xcodeproj. Both compile the same
// models from App/Model.
import PackageDescription

let root = Context.packageDirectory
let companionCoreLib = "\(root)/AstroBoxBridge/target/release"
// The companion core (AstroBoxBridge, Rust) builds for macOS and Windows; on
// Linux AstroBox's frontbridge needs its CEF runtime, so that build leaves it out.
let companionCoreHosts: [Platform] = [.macOS, .windows]
let withCompanionCore = TargetDependencyCondition.when(platforms: companionCoreHosts)
let companionCorePlatforms = BuildSettingCondition.when(platforms: companionCoreHosts)

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
                .product(name: "GtkBackend", package: "swift-cross-ui",
                         condition: .when(platforms: [.macOS, .linux])),
                .product(name: "Gtk", package: "swift-cross-ui",
                         condition: .when(platforms: [.macOS, .linux])),
                .product(name: "WinUIBackend", package: "swift-cross-ui",
                         condition: .when(platforms: [.windows])),
                .target(name: "CMirageAstroBox", condition: withCompanionCore),
            ],
            path: ".",
            exclude: [
                "External", "AstroBoxBridge", "Packages", "Scripts", "Mirage.xcodeproj",
                "App/Views", "App/Resources", "App/MirageApp.swift", "CrossApp/CMirageAstroBox",
                "README.md", "project.yml", "LICENSE",
            ],
            sources: ["CrossApp/Sources", "App/Model"],
            swiftSettings: [
                .define("MIRAGE_ASTROBOX", companionCorePlatforms),
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", companionCoreLib], companionCorePlatforms),
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
                // what `cargo rustc -- --print native-static-libs` lists for
                // x86_64-pc-windows-msvc; the windows.0.x import libraries are
                // copied next to the static library by build-companion-core.ps1
                .linkedLibrary("bcrypt", .when(platforms: [.windows])),
                .linkedLibrary("advapi32", .when(platforms: [.windows])),
                .linkedLibrary("kernel32", .when(platforms: [.windows])),
                .linkedLibrary("ntdll", .when(platforms: [.windows])),
                .linkedLibrary("userenv", .when(platforms: [.windows])),
                .linkedLibrary("ws2_32", .when(platforms: [.windows])),
                .linkedLibrary("dbghelp", .when(platforms: [.windows])),
                .linkedLibrary("windows.0.48.5", .when(platforms: [.windows])),
                .linkedLibrary("windows.0.52.0", .when(platforms: [.windows])),
            ]
        ),
    ]
)
