import SwiftUI

/// The practice page's own colours: a dark stage, no outlines, one accent. It does not use
/// `Theme` (the rest of the app's palette) and looks the same in light and dark appearance.
struct PracticePalette: Equatable {
    var name: String
    var ground: Color, stage: Color, keyBed: Color
    var surface: Color, selected: Color, rail: Color
    var text: Color, secondary: Color, barLabel: Color
    var accent: Color
    /// Faint guide lines on the stage, drawn at low opacity.
    var line: Color
    var whiteKey: Color, blackKey: Color, keyLabel: Color
    /// A key that should be down now, and its label.
    var lit: Color, litLabel: Color
    /// A key pressed that should not be.
    var wrong: Color
    var note: Color, noteBlack: Color, sounding: Color, glow: Color

    private static func hex(_ v: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: alpha)
    }

    /// Warm graphite, ivory keys, amber notes.
    static let amber = PracticePalette(
        name: "amber",
        ground: hex(0x161514), stage: hex(0x0F0E0D), keyBed: hex(0x0A0A09),
        surface: hex(0x1F1E1C), selected: hex(0x36332F), rail: hex(0x2B2926),
        text: hex(0xEDE9E1), secondary: hex(0xA8A297), barLabel: hex(0x8F897E),
        accent: hex(0xE8A33D), line: hex(0xFFF4E1),
        whiteKey: hex(0xE9E3D6), blackKey: hex(0x1B1A18), keyLabel: hex(0x5F594E),
        lit: hex(0xF0AE45), litLabel: hex(0x3A2A0C), wrong: hex(0xD8574A),
        note: hex(0xC98A2E), noteBlack: hex(0xA87224), sounding: hex(0xFFC255), glow: hex(0xFFC255, 0.55))

    /// Neutral graphite, cool white keys, pale notes with a blue accent.
    static let cool = PracticePalette(
        name: "cool",
        ground: hex(0x141517), stage: hex(0x0D0E10), keyBed: hex(0x08090A),
        surface: hex(0x1D1F22), selected: hex(0x33363B), rail: hex(0x282B2F),
        text: hex(0xECEEF0), secondary: hex(0xA3A8AF), barLabel: hex(0x8A9099),
        accent: hex(0x6FA8FF), line: hex(0xE6EEFF),
        whiteKey: hex(0xE4E7EA), blackKey: hex(0x17181A), keyLabel: hex(0x565B62),
        lit: hex(0x6FA8FF), litLabel: hex(0x0B2247), wrong: hex(0xF08A4B),
        note: hex(0x9AA5B2), noteBlack: hex(0x768291), sounding: hex(0xA9CBFF), glow: hex(0x6FA8FF, 0.6))

    static func named(_ name: String) -> PracticePalette { name == "cool" ? .cool : .amber }
}
