import MusicnoteCore
import SwiftUI

/// Horizontal keyboard. Highlighted keys get the soft red fill plus a dot, so they
/// don't rely on hue alone. Display and sound read the same pitch array.
struct KeyboardView: View {
    var pitches: [Int]
    var minOctaves = 2
    var height: CGFloat = 64
    var flats = false

    private var range: ClosedRange<Int> {
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
        Canvas { ctx, size in
            let ww = size.width / CGFloat(whites.count)
            var xFor: [Int: CGFloat] = [:]
            for (i, p) in whites.enumerated() {
                let rect = CGRect(x: CGFloat(i) * ww, y: 0, width: ww, height: size.height)
                xFor[p] = rect.minX
                ctx.fill(Path(rect), with: .color(set.contains(p) ? Theme.keyActive : .white))
                ctx.stroke(Path(rect), with: .color(Color.gray.opacity(0.5)), lineWidth: 0.5)
                if set.contains(p) {
                    ctx.fill(Path(ellipseIn: CGRect(x: rect.midX - 3, y: size.height - 12, width: 6, height: 6)), with: .color(Theme.accent))
                }
                if p % 12 == 0 {
                    ctx.draw(Text("C\(p / 12 - 1)").font(.system(size: 7)).foregroundColor(.gray), at: CGPoint(x: rect.midX, y: size.height - 22))
                }
            }
            for p in r where Self.isBlack(p) {
                guard let left = xFor[p - 1] else { continue }
                let bw = ww * 0.6
                let rect = CGRect(x: left + ww - bw / 2, y: 0, width: bw, height: size.height * 0.6)
                ctx.fill(Path(rect), with: .color(set.contains(p) ? Theme.accent : Color(white: 0.15)))
                if set.contains(p) {
                    ctx.fill(Path(ellipseIn: CGRect(x: rect.midX - 2.5, y: rect.maxY - 9, width: 5, height: 5)), with: .color(.white))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("键盘：" + pitches.sorted().map { Pitch.noteName($0, flats: flats) }.joined(separator: "、"))
    }

    static func isBlack(_ p: Int) -> Bool { [1, 3, 6, 8, 10].contains(p % 12) }
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
    private var shown: [Int] {
        if useStandard || original == nil { return standard }
        return Array(Set(original!.map(\.pitch))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(symbol).font(.system(size: 18, weight: .semibold))
                if let degree { Text(degree).font(.control13).foregroundStyle(Theme.textSecondary) }
                Spacer()
                if original != nil {
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
        if !useStandard, let o = original {
            AudioEngine.shared.playNotes(o.map { (pitch: $0.pitch, start: $0.start, duration: $0.duration, velocity: 96) })
        } else { AudioEngine.shared.playChord(standard) }
    }
}
