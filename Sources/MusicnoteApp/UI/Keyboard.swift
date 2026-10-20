import MusicnoteCore
import SwiftUI

/// Horizontal keyboard. Highlighted keys get the soft red fill plus a dot, so they
/// don't rely on hue alone. Display and sound read the same pitch array.
struct KeyboardView: View {
    var pitches: [Int]
    var minOctaves = 2
    var height: CGFloat = 64
    var flats = false
    /// A range that stays put while the pitches change (so movement between chords shows).
    var fixedRange: ClosedRange<Int>? = nil
    /// Keys of the previous chord, marked faintly.
    var ghost: [Int] = []
    /// When set, clicking a key reports its pitch (editing a voicing).
    var onKeyTap: ((Int) -> Void)? = nil

    private var range: ClosedRange<Int> {
        if let fixedRange { return fixedRange }
        guard let lo = pitches.min(), let hi = pitches.max() else { return 48...71 }
        var start = (lo / 12) * 12
        var end = ((hi / 12) + 1) * 12 - 1
        while end - start + 1 < minOctaves * 12 { if start > 24 { start -= 12 } else { end += 12 } }
        return start...end
    }

    var body: some View {
        let r = range
        let whites = r.filter { !Self.isBlack($0) }
        let set = Set(pitches)
        let ghostSet = Set(ghost)
        let big = height >= 90
        Canvas { ctx, size in
            let ww = size.width / CGFloat(whites.count)
            var xFor: [Int: CGFloat] = [:]
            for (i, p) in whites.enumerated() {
                let rect = CGRect(x: CGFloat(i) * ww, y: 0, width: ww, height: size.height)
                xFor[p] = rect.minX
                let key = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0), cornerSize: CGSize(width: 2.5, height: 2.5))
                ctx.fill(key, with: .color(set.contains(p) ? Theme.keyActive : Theme.keyWhite))
                ctx.stroke(key, with: .color(Theme.keyLine), lineWidth: 0.5)
                if set.contains(p) {
                    ctx.fill(Path(ellipseIn: CGRect(x: rect.midX - 3, y: size.height - 12, width: 6, height: 6)), with: .color(Theme.accent))
                    if big {
                        ctx.draw(Text(Pitch.noteName(p, flats: flats)).font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.keyActiveText),
                                 at: CGPoint(x: rect.midX, y: size.height - 26))
                    }
                } else if ghostSet.contains(p) {
                    ctx.stroke(Path(ellipseIn: CGRect(x: rect.midX - 3.5, y: size.height - 12.5, width: 7, height: 7)), with: .color(Theme.accent.opacity(0.45)), lineWidth: 1.2)
                }
                if p % 12 == 0 {
                    ctx.draw(Text("C\(p / 12 - 1)").font(.system(size: 7)).foregroundColor(Theme.textSecondary), at: CGPoint(x: rect.midX, y: size.height - 22))
                }
            }
            for p in r where Self.isBlack(p) {
                guard let left = xFor[p - 1] else { continue }
                let bw = ww * 0.6
                let rect = CGRect(x: left + ww - bw / 2, y: 0, width: bw, height: size.height * 0.6)
                ctx.fill(Path(roundedRect: rect, cornerSize: CGSize(width: 2, height: 2)), with: .color(set.contains(p) ? Theme.accent : Theme.keyBlack))
                if set.contains(p) {
                    ctx.fill(Path(ellipseIn: CGRect(x: rect.midX - 2.5, y: rect.maxY - 9, width: 5, height: 5)), with: .color(.white))
                    if big {
                        ctx.draw(Text(Pitch.noteName(p, flats: flats)).font(.system(size: 9, weight: .semibold)).foregroundColor(.white),
                                 at: CGPoint(x: rect.midX, y: rect.maxY - 20))
                    }
                } else if ghostSet.contains(p) {
                    ctx.stroke(Path(ellipseIn: CGRect(x: rect.midX - 3, y: rect.maxY - 9.5, width: 6, height: 6)), with: .color(.white.opacity(0.6)), lineWidth: 1.2)
                }
            }
        }
        .frame(height: height)
        .overlay {
            if let onKeyTap {
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { p in
                            if let k = Self.key(at: p, size: geo.size, range: r) { onKeyTap(k) }
                        }
                        .onHover { inside in if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("键盘：" + pitches.sorted().map { Pitch.noteName($0, flats: flats) }.joined(separator: "、"))
    }

    static func isBlack(_ p: Int) -> Bool { [1, 3, 6, 8, 10].contains(p % 12) }

    /// The key under a point, black keys first (they sit on top), laid out as drawn.
    static func key(at p: CGPoint, size: CGSize, range r: ClosedRange<Int>) -> Int? {
        let whites = r.filter { !isBlack($0) }
        guard !whites.isEmpty else { return nil }
        let ww = size.width / CGFloat(whites.count)
        if p.y <= size.height * 0.6 {
            for b in r where isBlack(b) {
                guard let i = whites.firstIndex(of: b - 1) else { continue }
                let x = CGFloat(i) * ww + ww - ww * 0.3
                if p.x >= x && p.x <= x + ww * 0.6 { return b }
            }
        }
        let i = Int(p.x / ww)
        return whites.indices.contains(i) ? whites[i] : nil
    }
}

/// The shared chord preview used in notes, cards and chat. When an event is linked,
/// "片段按法" shows that event's real voicing; otherwise the standard voicing.
struct ChordPreviewCard: View {
    @Environment(AppModel.self) private var model
    var symbol: String
    var original: [(pitch: Int, start: Double, duration: Double)]? = nil
    var degree: String? = nil
    @ViewState private var useStandard = false

    private var standard: [Int] { StandardVoicing.pitches(symbol: symbol) ?? [] }
    /// Chord tones as struck in the clip (melody and passing notes left out); nil → standard.
    private var played: [Int]? { original.flatMap { PlayedVoicing.pitches(symbol: symbol, notes: $0) } }
    private var shown: [Int] { useStandard ? standard : (played ?? standard) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(symbol).font(.system(size: 18, weight: .semibold))
                if let degree { Text(degree).font(.control13).foregroundStyle(Theme.textSecondary) }
                Spacer()
                if played != nil {
                    Picker("", selection: $useStandard) { Text("片段按法").tag(false); Text("标准按法").tag(true) }
                        .pickerStyle(.segmented).frame(width: 150)
                }
                Button { play() } label: { Image(systemName: "play.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.borderless).help("用当前音色发声（\(model.settings.instrument.display)）")
                    .keyboardShortcut(.return, modifiers: [])
            }
            KeyboardView(pitches: shown, height: 72)
            Text(shown.map { Pitch.noteName($0) }.joined(separator: " ")).font(.caption12).foregroundStyle(Theme.textSecondary)
            if shown.isEmpty { Text("无法解析这个和弦符号").font(.caption12).foregroundStyle(Theme.warning) }
        }
        .padding(12)
        .frame(width: 400)
        .background(Theme.surfaceRaised)
    }

    private func play() {
        AudioEngine.shared.playChord(shown)
    }
}
