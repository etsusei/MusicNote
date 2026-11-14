import MusicnoteCore
import MusicnotePractice
import SwiftUI

/// The stage: notes falling toward the keyboard along the bottom edge. A note reaches the
/// play line as it should be struck and its key lights while it sounds. Drawn every frame
/// from the engine's clock, so the picture stays on the sound at any speed.
struct PracticeStageView: View {
    var session: PracticeSessionModel
    var palette: PracticePalette
    /// Seconds of music between the top of the stage and the play line.
    var lookahead: Double
    /// Keys held on the connected keyboard, each right or wrong (empty when none is connected).
    var pressed: [Int: PracticeJudge.Verdict] = [:]
    /// Moves the picture later (positive) or earlier against the sound, in seconds.
    var visualOffset: Double = 0
    var playing: Bool

    var body: some View {
        // Read here so a seek or a new loop redraws the stage while paused.
        let _ = session.redraw
        TimelineView(.animation(paused: !playing)) { timeline in
            // The frame's date has to be an input of the canvas: SwiftUI redraws a canvas only
            // when what its closure captures has changed, and nothing else here changes
            // from frame to frame (the position is read from the engine while drawing).
            let frame = timeline.date
            Canvas(opaque: true) { ctx, size in
                _ = frame
                draw(&ctx, size)
            }
        }
        .accessibilityLabel("下落音符和键盘")
    }

    /// Frames drawn so far, for the debug driver to check that the stage animates by itself.
    nonisolated(unsafe) static var framesDrawn = 0

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        Self.framesDrawn += 1
        let keysHeight = min(160, max(96, size.height * 0.2))
        let stageHeight = size.height - keysHeight
        let width = size.width
        let now = session.visualUs(offsetSeconds: visualOffset)
        let windowUs = Int64(lookahead * 1_000_000)
        let perUs = stageHeight / CGFloat(max(windowUs, 1))
        func y(_ us: Int64) -> CGFloat { stageHeight - CGFloat(us - now) * perUs }

        ctx.fill(Path(CGRect(x: 0, y: 0, width: width, height: stageHeight)), with: .color(palette.stage))

        // Octave guides: a faint line at the left edge of every C.
        for pitch in stride(from: 24, through: 108, by: 12) {
            guard let f = PianoKeys.frame(pitch) else { continue }
            ctx.fill(Path(CGRect(x: CGFloat(f.x) * width, y: 0, width: 1, height: stageHeight)), with: .color(palette.line.opacity(0.05)))
        }

        // Bar lines with their numbers.
        for line in session.bars.lines where line.us >= now - 200_000 && line.us <= now + windowUs {
            let ly = y(line.us)
            ctx.fill(Path(CGRect(x: 0, y: ly, width: width, height: 1)), with: .color(palette.line.opacity(0.1)))
            ctx.draw(Text("\(line.number)").font(.system(size: 12).monospacedDigit()).foregroundColor(palette.barLabel),
                     at: CGPoint(x: 14, y: ly - 5), anchor: .bottomLeading)
        }

        // The loop's ends.
        if session.loopOn, let loop = session.loop {
            for (us, name) in [(loop.lowerBound, "A"), (loop.upperBound, "B")] where us >= now - 200_000 && us <= now + windowUs {
                let ly = y(us)
                ctx.fill(Path(CGRect(x: 0, y: ly - 0.5, width: width, height: 2)), with: .color(palette.accent.opacity(0.55)))
                ctx.draw(Text(name).font(.system(size: 12, weight: .semibold)).foregroundColor(palette.accent),
                         at: CGPoint(x: width - 14, y: ly - 5), anchor: .bottomTrailing)
            }
        }

        // The sustain pedal: a strip down the right edge while it is held.
        if !session.pedals.isEmpty {
            for span in session.pedals where span.endUs > now && span.startUs < now + windowUs {
                let top = max(0, y(span.endUs)), bottom = min(stageHeight, y(span.startUs))
                guard bottom > top else { continue }
                ctx.fill(Path(roundedRect: CGRect(x: width - 7, y: top, width: 3, height: bottom - top), cornerRadius: 1.5),
                         with: .color(palette.accent.opacity(0.5)))
            }
        }

        // Notes: the part above the play line, the sounding ones brighter with a glow.
        let notes = session.timeline.notes
        var sounding = Set<Int>()
        var glowing = Path()
        for i in session.timeline.visible(fromUs: now, toUs: now + windowUs) {
            let n = notes[i]
            guard let f = PianoKeys.frame(n.pitch) else { continue }
            let black = PianoKeys.isBlack(n.pitch)
            let inset = black ? 0 : CGFloat(f.width) * width * 0.1
            let top = y(n.endUs) + 1.5, bottom = min(stageHeight, y(n.startUs))
            let rect = CGRect(x: CGFloat(f.x) * width + inset, y: min(top, bottom - 4), width: CGFloat(f.width) * width - inset * 2,
                              height: max(4, bottom - top))
            let path = Path(roundedRect: rect, cornerRadius: min(5, rect.height / 2, rect.width / 2))
            if n.startUs <= now {
                sounding.insert(n.pitch)
                glowing.addPath(path)
            } else {
                ctx.fill(path, with: .color(black ? palette.noteBlack : palette.note))
            }
        }
        if !glowing.isEmpty {
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: palette.glow, radius: 9))
                layer.fill(glowing, with: .color(palette.sounding))
            }
        }

        // The play line, where the stage meets the keys.
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: palette.accent.opacity(0.7), radius: 8))
            layer.fill(Path(CGRect(x: 0, y: stageHeight - 2, width: width, height: 2)), with: .color(palette.accent))
        }

        // A right key answers with a spark on the play line above it.
        var sparks = Path()
        for (pitch, verdict) in pressed where verdict == .hit {
            guard let f = PianoKeys.frame(pitch) else { continue }
            sparks.addPath(Path(roundedRect: CGRect(x: CGFloat(f.x) * width, y: stageHeight - 5, width: CGFloat(f.width) * width, height: 6), cornerRadius: 3))
        }
        if !sparks.isEmpty {
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: palette.glow, radius: 12))
                layer.fill(sparks, with: .color(palette.sounding))
            }
        }

        // Waiting: the keys still owed are lit and marked, also when their note was short and
        // has already gone from the stage.
        let owed = session.awaitedPitches(atUs: now)
        drawKeys(&ctx, CGRect(x: 0, y: stageHeight, width: width, height: keysHeight), sounding: sounding.union(owed), owed: owed)
    }

    /// The keyboard. A key is lit while its note sounds. With a keyboard connected, a key held
    /// shows how it was judged when it went down: brighter when right, the wrong colour when not.
    /// While waiting, a key still owed carries a dot until it is pressed.
    private func drawKeys(_ ctx: inout GraphicsContext, _ frame: CGRect, sounding: Set<Int>, owed: Set<Int> = []) {
        func dot(_ rect: CGRect, _ pitch: Int, y: CGFloat) {
            guard owed.contains(pitch), pressed[pitch] != .hit else { return }
            let d = min(rect.width * 0.5, 12)
            ctx.fill(Path(ellipseIn: CGRect(x: rect.midX - d / 2, y: y - d / 2, width: d, height: d)), with: .color(palette.litLabel))
        }
        ctx.fill(Path(frame), with: .color(palette.keyBed))
        func colour(_ pitch: Int, plain: Color) -> Color {
            switch pressed[pitch] {
            case .wrong?: return palette.wrong
            case .hit?: return palette.sounding
            case nil: return sounding.contains(pitch) ? palette.lit : plain
            }
        }
        for pitch in PianoKeys.lowest...PianoKeys.highest where !PianoKeys.isBlack(pitch) {
            guard let f = PianoKeys.frame(pitch) else { continue }
            let rect = CGRect(x: frame.minX + CGFloat(f.x) * frame.width, y: frame.minY, width: CGFloat(f.width) * frame.width - 1, height: frame.height)
            let path = Path(roundedRect: rect, cornerSize: CGSize(width: 3, height: 3))
            let lit = sounding.contains(pitch) || pressed[pitch] != nil
            ctx.fill(path, with: .color(colour(pitch, plain: palette.whiteKey)))
            if let label = PianoKeys.cLabel(pitch), rect.width >= 16 {
                ctx.draw(Text(label).font(.system(size: 10)).foregroundColor(lit ? palette.litLabel : palette.keyLabel),
                         at: CGPoint(x: rect.midX, y: rect.maxY - 8), anchor: .bottom)
            }
            dot(rect, pitch, y: rect.maxY - 34)
        }
        // The keys sit under the stage: a soft shadow along their top edge.
        ctx.fill(Path(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 9)),
                 with: .linearGradient(Gradient(colors: [.black.opacity(0.4), .black.opacity(0)]),
                                       startPoint: CGPoint(x: 0, y: frame.minY), endPoint: CGPoint(x: 0, y: frame.minY + 9)))
        for pitch in PianoKeys.lowest...PianoKeys.highest where PianoKeys.isBlack(pitch) {
            guard let f = PianoKeys.frame(pitch) else { continue }
            let rect = CGRect(x: frame.minX + CGFloat(f.x) * frame.width, y: frame.minY, width: CGFloat(f.width) * frame.width, height: frame.height * 0.6)
            ctx.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 2), cornerSize: CGSize(width: 2.5, height: 2.5)), with: .color(.black.opacity(0.45)))
            ctx.fill(Path(roundedRect: rect, cornerSize: CGSize(width: 2.5, height: 2.5)), with: .color(colour(pitch, plain: palette.blackKey)))
            dot(rect, pitch, y: rect.maxY - 14)
        }
    }
}
