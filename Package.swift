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
        // Rubber Band Library 4.0.0 (GPL), built from its single-file compilation unit; Swift
        // uses the C interface in include/. See Sources/RubberBand/README.md.
        .target(
            name: "RubberBand",
            exclude: ["README.md", "vendor/COPYING", "vendor/README.md", "vendor/CHANGELOG", "vendor/src", "vendor/rubberband"],
            sources: ["vendor/single/RubberBandSingle.cpp"],
            // Optimised in debug builds too: the stretcher has to keep up with real time.
            cxxSettings: [.unsafeFlags(["-O2", "-w"])],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        // Practice mode's own logic (MIDI back from Logic, alignment, time-stretched playback);
        // the pages are in MusicnoteApp.
        .target(
            name: "MusicnotePractice",
            dependencies: ["MusicnoteCore", "RubberBand"]
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
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
