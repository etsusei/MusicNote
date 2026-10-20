import AppKit
import SwiftUI

/// SwiftUI's `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode;
/// the underlying property wrapper works the same when named through an alias.
typealias ViewState = SwiftUI.State

/// Visual tokens: cool neutral greys (zinc) with one deep indigo accent for actions, selection
/// and what is sounding; chords and notes in a calm slate-teal so the two never blur. Light and
/// dark are tuned separately rather than inverted.
enum Theme {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // Surfaces
    static let background = dyn(0xF7F7F8, 0x111113)
    static let surface = dyn(0xFFFFFF, 0x18181B)
    static let surfaceRaised = dyn(0xFFFFFF, 0x222226)
    static let sidebar = dyn(0xF1F1F3, 0x0C0C0E)
    // Text
    static let textPrimary = dyn(0x18181B, 0xEDEDEF)
    static let textSecondary = dyn(0x71717A, 0x9D9DA6)
    // Lines
    static let borderSubtle = dyn(0xE6E6EA, 0x26262B)
    static let controlBorder = dyn(0xD4D4DA, 0x3A3A41)
    // Accent (indigo)
    static let accent = dyn(0x5856D6, 0x8582FF)
    static let onAccent = dyn(0xFFFFFF, 0x0E0E14)
    static let accentHover = dyn(0x4C4ACB, 0x9895FF)
    static let accentPressed = dyn(0x4341B8, 0x726EF0)
    static let selectionFill = dyn(0xECECFD, 0x24233D)
    static let keyActive = dyn(0xC9C8FA, 0x6E6BE8)
    static let keyActiveText = dyn(0x3B39A8, 0xFFFFFF)
    // Chords and notes (slate-teal)
    static let noteFill = dyn(0x3E6F79, 0x8CC3CB)
    static let onNote = dyn(0xFFFFFF, 0x0B1A1D)
    /// Chord chips: tinted, so a page of chords stays calm; only the sounding one goes solid.
    static let chipFill = dyn(0xE4EFF1, 0x203438)
    static let chipText = dyn(0x1F4A53, 0xBFE3E8)
    static let chipLine = dyn(0xBFD6DB, 0x37575E)
    // Keyboard
    static let keyWhite = dyn(0xFFFFFF, 0xDCDCE1)
    static let keyBlack = dyn(0x232327, 0x141416)
    static let keyLine = dyn(0xD9D9DE, 0x8E8E96)
    // Status
    static let success = dyn(0x2E7D5B, 0x74C69D)
    static let warning = dyn(0xB4690E, 0xE9B45F)
    static let error = dyn(0xC0392B, 0xF08A80)
    static let highlight = dyn(0xFDF1C7, 0x3A3221)
    // Elevation (light theme only; dark relies on surface steps)
    static let shadow = dyn(0x000000, 0x000000)
    static var shadowOpacity: Double { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0 : 0.05 }

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
                .fill(configuration.isPressed ? Theme.accentPressed : Theme.accent)
                .shadow(color: Theme.accent.opacity(enabled ? 0.25 : 0), radius: 6, y: 2))
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
                .fill(configuration.isPressed ? Theme.selectionFill : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous).stroke(Theme.controlBorder, lineWidth: 1))
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
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface)
                .shadow(color: Theme.shadow.opacity(Theme.shadowOpacity), radius: 8, y: 2))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.borderSubtle, lineWidth: 1))
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

/// Small tinted label (key, tempo, state…).
struct StatusPill: View {
    var text: String
    var color: Color = Theme.textSecondary
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
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
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surfaceRaised)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.borderSubtle.opacity(0.7)))
    }
}

/// A quiet notice row: icon, title, detail, one action.
extension View {
    func noticeBox(_ tint: Color = Theme.accent) -> some View {
        padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.18)))
    }
}
