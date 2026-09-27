// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinderPlus",
    // macOS 26 rather than the usual 14: Liquid Glass (`glassEffect`, `GlassEffectContainer`, the
    // `.glass` button styles, `safeAreaBar`) is the point of the app and exists nowhere earlier.
    // Back-deploying would mean an availability fork around every surface in the UI. The string
    // form because `.v26` needs tools 6.2 and nothing else here does.
    platforms: [.macOS("26.0")],
    dependencies: [
        // Updates. Distributed as a binary XCFramework, so build.sh has to copy it into
        // Contents/Frameworks, add an rpath, and sign it before the app — see the comments there.
        // At least the version Cmd-Tab ships.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        .executableTarget(
            name: "FinderPlus",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/FinderPlus",
            // Swift 6 language mode. The search walks the disk on a detached task and fans content
            // reads out across every core, then hands hits back to the main actor — exactly the
            // handoff strict concurrency can prove. The one type it cannot (`NSRegularExpression`)
            // is marked `@unchecked Sendable` where it is wrapped, with the reason beside it.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FinderPlusTests",
            dependencies: ["FinderPlus"],
            path: "Tests/FinderPlusTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
