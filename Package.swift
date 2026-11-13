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
        // Practice mode's own logic (MIDI back from Logic, alignment); the pages are in MusicnoteApp.
        .target(
            name: "MusicnotePractice",
            dependencies: ["MusicnoteCore"]
        ),
        .executableTarget(
            name: "MusicnoteApp",
            dependencies: ["MusicnoteCore", "MusicnotePractice"]
        ),
        .executableTarget(name: "StemSeparator"),
        // The command line tools ship without XCTest or the swift-testing
        // macro plugin, so checks run as an executable: `swift run MusicnoteChecks`.
        .executableTarget(
            name: "MusicnoteChecks",
            dependencies: ["MusicnoteCore", "MusicnotePractice"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
