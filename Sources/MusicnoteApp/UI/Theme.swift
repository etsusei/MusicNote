import AppKit
import SwiftUI

/// SwiftUI's `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode;
/// the underlying property wrapper works the same when named through an alias.
typealias ViewState = SwiftUI.State

/// Visual tokens. Two palettes, each tuned for dark and for light: amber (warm graphite with
/// one amber accent, the default) and cool (neutral graphite with a blue accent). The same
/// choice colours the practice page (`PracticePalette`). One accent only: actions, selection
/// and what is sounding share it; everything else is a step of the neutral.
enum Theme {
    /// UserDefaults key of the palette, shared with the practice page.
    static let paletteKey = "practicePalette"
    /// Whether the cool palette is chosen. Read when a colour is resolved, so it is kept here
    /// rather than fetched from the defaults each time.
    nonisolated(unsafe) private(set) static var cool = UserDefaults.standard.string(forKey: paletteKey) == "cool"
    nonisolated(unsafe) private static var watching: NSObjectProtocol?

    /// Follows the palette setting from now on. Views already on screen keep the colours they
    /// resolved; the root view is rebuilt when the setting changes (see RootView).
    static func watchPalette() {
        guard watching == nil else { return }
        watching = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            cool = UserDefaults.standard.string(forKey: paletteKey) == "cool"
        }
    }

    /// A colour given as (light, dark) for the amber palette and for the cool one.
    private static func dyn(_ amber: (UInt32, UInt32), _ coolPair: (UInt32, UInt32)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let pair = cool ? coolPair : amber
            return NSColor(hex: isDark ? pair.1 : pair.0)
        })
    }

    // Surfaces: the ground, a block resting on it, a control resting on a block.
    static let background = dyn((0xF6F3EE, 0x161514), (0xF5F6F8, 0x141517))
    static let surface = dyn((0xFFFDF9, 0x1F1E1C), (0xFFFFFF, 0x1D1F22))
    static let surfaceRaised = dyn((0xEFEAE1, 0x2C2A27), (0xECEEF2, 0x292C30))
    static let sidebar = dyn((0xEFEBE4, 0x111010), (0xECEEF1, 0x101113))
    /// The block behind a song's initial where it has no artwork; it has to show on the
    /// sidebar, on the ground and on a selected row alike.
    static let tile = dyn((0xDDD6C9, 0x2C2A27), (0xD7DCE3, 0x292C30))
    // Text
    static let textPrimary = dyn((0x1F1C17, 0xEDE9E1), (0x18191B, 0xECEEF0))
    static let textSecondary = dyn((0x756E62, 0xA8A297), (0x6B7078, 0xA3A8AF))
    // Lines: hairlines between regions, and the edge of a control that needs one (a text field).
    static let borderSubtle = dyn((0xE6E0D6, 0x2B2926), (0xE3E5E9, 0x282B2F))
    static let controlBorder = dyn((0xD3CCBF, 0x403C37), (0xCFD3D9, 0x3C4046))
    // Accent
    static let accent = dyn((0xA9650A, 0xE8A33D), (0x2F6FDB, 0x6FA8FF))
    static let onAccent = dyn((0xFFFFFF, 0x1B1407), (0xFFFFFF, 0x08172E))
    static let accentHover = dyn((0x9A5B06, 0xF0AE45), (0x2862C6, 0x8AB9FF))
    static let accentPressed = dyn((0x8A5104, 0xCF8F30), (0x2156B0, 0x5A93EA))
    /// The tint of ordinary controls (borderless buttons, menus, segmented pickers, checkboxes):
    /// a neutral, so that the accent is left for the one main action and for what is sounding.
    static let controlTint = dyn((0x4A453D, 0xCFC9BD), (0x444A52, 0xC9CED6))
    /// What is selected or pressed: a step of the neutral, not a tint.
    static let selectionFill = dyn((0xE7E1D6, 0x34312D), (0xE1E5EC, 0x30343A))
    static let keyActive = dyn((0xF2C879, 0xF0AE45), (0xBDD5FB, 0x6FA8FF))
    static let keyActiveText = dyn((0x5A3A05, 0x3A2A0C), (0x123A7A, 0x0B2247))
    // Chords and notes: the accent's own family, a little quieter than the accent itself.
    static let noteFill = dyn((0xB9791C, 0xC98A2E), (0x4F7FCC, 0x86B2F5))
    static let onNote = dyn((0xFFFFFF, 0x1B1407), (0xFFFFFF, 0x08172E))
    /// Chord chips: neutral, so a page of chords stays calm; only the sounding one goes solid.
    static let chipFill = dyn((0xEFEAE1, 0x2C2A27), (0xECEEF2, 0x292C30))
    static let chipText = dyn((0x2A2620, 0xEDE9E1), (0x23272D, 0xECEEF0))
    static let chipLine = dyn((0xD9D2C5, 0x4A463F), (0xD3D8DF, 0x464A51))
    // Keyboard
    static let keyWhite = dyn((0xFFFFFF, 0xE9E3D6), (0xFFFFFF, 0xE4E7EA))
    static let keyBlack = dyn((0x26231F, 0x1B1A18), (0x232427, 0x17181A))
    static let keyLine = dyn((0xD9D3C8, 0xA39C8D), (0xD9DCE1, 0x9AA0A8))
    // Status
    static let success = dyn((0x2E7D5B, 0x8DBF8B), (0x2E7D5B, 0x7FC79A))
    static let warning = dyn((0xB4540E, 0xE58A4E), (0xB4690E, 0xF0A45B))
    static let error = dyn((0xC0392B, 0xE0685C), (0xC0392B, 0xF08A80))
    static let highlight = dyn((0xFBEBC2, 0x3D321C), (0xDCE8FC, 0x1F2D45))
    // Elevation (light theme only; dark relies on surface steps)
    static let shadow = dyn((0x000000, 0x000000), (0x000000, 0x000000))
    static var shadowOpacity: Double { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0 : 0.04 }

    static func ns(_ c: Color) -> NSColor { NSColor(c) }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Font {
    static let pageTitle = Font.system(size: 26, weight: .semibold).width(.standard)
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let body14 = Font.system(size: 14)
    static let control13 = Font.system(size: 13)
    static let caption12 = Font.system(size: 12)
    static let mono13 = Font.system(size: 13).monospacedDigit()
}

/// The one emphasized action per flow area.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(configuration.isPressed ? Theme.accentPressed : Theme.accent))
            .foregroundStyle(Theme.onAccent)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 10 : 14).frame(minHeight: compact ? 26 : 32)
            .background(RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous)
                .fill(configuration.isPressed ? Theme.selectionFill : Theme.surfaceRaised))
            .foregroundStyle(Theme.textPrimary)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface)
                .shadow(color: Theme.shadow.opacity(Theme.shadowOpacity), radius: 8, y: 2))
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.sectionTitle).tracking(-0.1).foregroundStyle(Theme.textPrimary)
            if let subtitle { Text(subtitle).font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Top of a page: large title and one line of context.
struct PageHeader: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.pageTitle).foregroundStyle(Theme.textPrimary)
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary) }
        }
    }
}

/// Small quiet label (key, tempo, state…).
struct StatusPill: View {
    var text: String
    var color: Color = Theme.textSecondary
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.13)))
            .foregroundStyle(color)
    }
}

/// Pill tabs on a soft track; the chosen one lifts onto the surface.
struct PillTabs: View {
    var titles: [String]
    @Binding var selection: Int
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                Button { withAnimation(.snappy(duration: 0.22)) { selection = i } } label: {
                    Text(t).font(.system(size: 12.5, weight: selection == i ? .semibold : .medium))
                        .foregroundStyle(selection == i ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background {
                            if selection == i {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.selectionFill)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
    }
}

/// A quiet notice row: icon, title, detail, one action.
extension View {
    func noticeBox(_ tint: Color = Theme.accent) -> some View {
        padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.09)))
    }
}
