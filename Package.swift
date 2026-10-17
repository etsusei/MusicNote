// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Musicnote",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Musicnote", targets: ["MusicnoteApp"]),
        .executable(name: "musicnote-separate", targets: ["StemSeparator"]),
    ],
    targets: [
        .target(
            name: "MusicnoteCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "MusicnoteApp",
            dependencies: ["MusicnoteCore"]
        ),
        .executableTarget(name: "StemSeparator"),
        // The command line tools ship without XCTest or the swift-testing
        // macro plugin, so checks run as an executable: `swift run MusicnoteChecks`.
        .executableTarget(
            name: "MusicnoteChecks",
            dependencies: ["MusicnoteCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
