import AppKit
import SwiftUI

/// SwiftUI's `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode;
/// the underlying property wrapper works the same when named through an alias.
typealias ViewState = SwiftUI.State

/// Visual tokens from the design doc: warm off-white light theme, low-saturation charcoal dark theme.
enum Theme {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let background = dyn(0xF7F4EE, 0x181A1B)
    static let surface = dyn(0xFFFCF7, 0x232629)
    static let surfaceRaised = dyn(0xFFFFFF, 0x2D3135)
    static let textPrimary = dyn(0x282723, 0xE7E5DF)
    static let textSecondary = dyn(0x69665F, 0xADB0AC)
    static let borderSubtle = dyn(0xDDD7CD, 0x454A4F)
    static let controlBorder = dyn(0x837C72, 0x828A91)
    static let accent = dyn(0x8F414B, 0xE3A3AA)
    static let onAccent = dyn(0xFFFFFF, 0x251B1D)
    static let accentHover = dyn(0x7D3540, 0xEDB7BD)
    static let accentPressed = dyn(0x6D2D37, 0xCF8F99)
    static let selectionFill = dyn(0xF1DDE0, 0x493139)
    static let keyActive = dyn(0xF0CBD0, 0xC78693)
    static let noteFill = dyn(0x49665B, 0xAAC8BB)
    static let onNote = dyn(0xFFFFFF, 0x17241E)
    static let success = dyn(0x37634E, 0xA3C7AD)
    static let warning = dyn(0x7A571D, 0xDFC18B)
    static let error = dyn(0x9A3842, 0xF0A5AC)
    static let highlight = dyn(0xF5E6B8, 0x4A4026)

    static func ns(_ c: Color) -> NSColor { NSColor(c) }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Font {
    static let pageTitle = Font.system(size: 24, weight: .semibold)
    static let sectionTitle = Font.system(size: 17, weight: .semibold)
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
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Theme.accentPressed : Theme.accent))
            .foregroundStyle(Theme.onAccent)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, compact ? 10 : 14).frame(minHeight: compact ? 28 : 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Theme.selectionFill : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.controlBorder.opacity(0.6), lineWidth: 1))
            .foregroundStyle(Theme.textPrimary)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderSubtle, lineWidth: 1))
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.sectionTitle).foregroundStyle(Theme.textPrimary)
            if let subtitle { Text(subtitle).font(.caption12).foregroundStyle(Theme.textSecondary) }
        }
    }
}

struct StatusPill: View {
    var text: String
    var color: Color = Theme.textSecondary
    var body: some View {
        Text(text).font(.caption12).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().stroke(color.opacity(0.7), lineWidth: 1))
            .foregroundStyle(color)
    }
}
