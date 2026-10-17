import AppKit
import MusicnoteCore
import SwiftUI

/// Audio waveform lane above a piano roll, on one shared time axis.
final class MidiEditorNSView: NSView {
    weak var controller: MidiEditorController?
    var peaks: WaveformPeaks?
    var playheadUs: Int64 = 0 { didSet { if oldValue != playheadUs { needsDisplay = true } } }
    var onSeek: ((Int64) -> Void)?
    var onLoop: ((Range<Int64>?) -> Void)?
    var instrumentPreview: ((Int) -> Void)?
    var stopPreview: (() -> Void)?
    var followPlayhead = true
    /// Fit to the clip once the view has real bounds.
    var pendingFit = true

    // Viewport
    var pxPerSecond: CGFloat = 120
    var timeOffsetUs: Int64 = 0
    var topPitch = 84
    var rowHeight: CGFloat = 12
    let keyWidth: CGFloat = 44
    let waveHeight: CGFloat = 90
    let rulerHeight: CGFloat = 18

    private enum DragMode { case none, move, resizeStart, resizeEnd, loop, seek }
    private var dragMode = DragMode.none
    private var dragNote: UUID?
    private var dragOrigin: CGPoint = .zero
    private var dragOriginal: MidiNote?
    private var dragOriginals: [UUID: MidiNote] = [:]
    private var lastPreviewPitch: Int?
    private var loopAnchorUs: Int64 = 0

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        if pendingFit, bounds.width > 200, bounds.height > 200, let c = controller {
            pendingFit = false
            scrollToFit(durationUs: c.durationUs)
        }
    }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    private var rollTop: CGFloat { rulerHeight + waveHeight }
    func x(us: Int64) -> CGFloat { keyWidth + CGFloat(Double(us - timeOffsetUs) / 1_000_000) * pxPerSecond }
    func us(x: CGFloat) -> Int64 { timeOffsetUs + Int64(Double((x - keyWidth) / pxPerSecond) * 1_000_000) }
    func y(pitch: Int) -> CGFloat { rollTop + CGFloat(topPitch - pitch) * rowHeight }
    func pitch(y: CGFloat) -> Int { topPitch - Int(floor((y - rollTop) / rowHeight)) }

    func noteRect(_ n: MidiNote) -> CGRect {
        CGRect(x: x(us: n.startUs), y: y(pitch: n.pitch) + 1, width: max(3, x(us: n.endUs) - x(us: n.startUs)), height: rowHeight - 2)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let c = controller else { return }
        let ctx = NSGraphicsContext.current!.cgContext
        let b = bounds
        Theme.ns(Theme.background).setFill(); b.fill()

        // Piano roll rows: white/black key alternation
        let lowPitch = pitch(y: b.maxY)
        for p in max(0, lowPitch)...min(127, topPitch) {
            let ry = y(pitch: p)
            let black = [1, 3, 6, 8, 10].contains(p % 12)
            (black ? Theme.ns(Theme.borderSubtle).withAlphaComponent(0.35) : Theme.ns(Theme.surface)).setFill()
            CGRect(x: keyWidth, y: ry, width: b.width - keyWidth, height: rowHeight).fill()
            if p % 12 == 0 {
                Theme.ns(Theme.borderSubtle).setFill()
                CGRect(x: keyWidth, y: ry + rowHeight - 0.5, width: b.width - keyWidth, height: 0.5).fill()
            }
        }

        // Beat grid (strong lines on downbeats when an anchor exists)
        if let g = c.grid {
            let startUs = us(x: keyWidth), endUs = us(x: b.maxX)
            var q = floor(g.q(atUs: startUs))
            while true {
                let t = g.us(atQ: q)
                if t > endUs { break }
                let gx = x(us: t)
                let strong = g.isDownbeat(q: q)
                Theme.ns(Theme.controlBorder).withAlphaComponent(strong ? 0.5 : 0.18).setFill()
                CGRect(x: gx, y: rulerHeight, width: strong ? 1.2 : 0.6, height: b.height - rulerHeight).fill()
                if c.snapDivision > 1 {
                    for k in 1..<c.snapDivision {
                        let sx = x(us: g.us(atQ: q + Double(k) / Double(c.snapDivision)))
                        Theme.ns(Theme.controlBorder).withAlphaComponent(0.07).setFill()
                        CGRect(x: sx, y: rollTop, width: 0.5, height: b.height - rollTop).fill()
                    }
                }
                q += 1
            }
        }

        // Ruler with loop region
        Theme.ns(Theme.surfaceRaised).setFill()
        CGRect(x: 0, y: 0, width: b.width, height: rulerHeight).fill()
        if let loop = c.loop {
            Theme.ns(Theme.selectionFill).setFill()
            CGRect(x: x(us: loop.lowerBound), y: 0, width: x(us: loop.upperBound) - x(us: loop.lowerBound), height: rulerHeight).fill()
        }
        let secondStep = pxPerSecond > 200 ? 0.5 : (pxPerSecond > 60 ? 1.0 : 5.0)
        var s = floor(Double(timeOffsetUs) / 1_000_000 / secondStep) * secondStep
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: Theme.ns(Theme.textSecondary)]
        while true {
            let t = Int64(s * 1_000_000)
            let rx = x(us: t)
            if rx > b.maxX { break }
            if rx >= keyWidth {
                NSString(string: String(format: "%.1fs", s)).draw(at: CGPoint(x: rx + 2, y: 3), withAttributes: attrs)
                Theme.ns(Theme.controlBorder).withAlphaComponent(0.4).setFill()
                CGRect(x: rx, y: rulerHeight - 5, width: 0.5, height: 5).fill()
            }
            s += secondStep
        }

        // Waveform lane
        Theme.ns(Theme.surface).setFill()
        CGRect(x: keyWidth, y: rulerHeight, width: b.width - keyWidth, height: waveHeight).fill()
        if let peaks {
            let startF = Int64(Double(us(x: keyWidth)) / 1_000_000 * peaks.sampleRate)
            let endF = Int64(Double(us(x: b.maxX)) / 1_000_000 * peaks.sampleRate)
            let cols = Int(b.width - keyWidth)
            let data = peaks.columns(cols, startFrame: max(0, startF), endFrame: max(startF + 1, endF))
            let offsetCols = startF < 0 ? Int(CGFloat(-startF) / CGFloat(max(1, endF - startF)) * CGFloat(cols)) : 0
            let mid = rulerHeight + waveHeight / 2
            Theme.ns(Theme.textSecondary).withAlphaComponent(0.7).setFill()
            for (i, (lo, hi)) in data.enumerated() where i >= offsetCols {
                let top = mid - CGFloat(min(1, hi)) * waveHeight * 0.48
                let bot = mid - CGFloat(max(-1, lo)) * waveHeight * 0.48
                CGRect(x: keyWidth + CGFloat(i), y: top, width: 1, height: max(1, bot - top)).fill()
            }
        }
        Theme.ns(Theme.borderSubtle).setFill()
        CGRect(x: 0, y: rollTop - 1, width: b.width, height: 1).fill()

        // Notes
        let visStart = us(x: keyWidth) - 10_000_000, visEnd = us(x: b.maxX)
        let playing = playheadUs
        for n in c.notes where n.endUs >= visStart && n.startUs <= visEnd && n.pitch <= topPitch + 1 && n.pitch >= lowPitch - 1 {
            let r = noteRect(n)
            let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            Theme.ns(Theme.noteFill).setFill(); path.fill()
            if c.selected.contains(n.id) {
                Theme.ns(Theme.accent).setStroke(); path.lineWidth = 2; path.stroke()
            }
            if n.edited { // small marker for edited notes
                Theme.ns(Theme.onNote).setFill()
                CGRect(x: r.minX + 2, y: r.midY - 1, width: 3, height: 2).fill()
            }
            if playing >= n.startUs && playing < n.endUs {
                Theme.ns(Theme.onNote).setFill()
                NSBezierPath(ovalIn: CGRect(x: r.maxX - 6, y: r.midY - 2, width: 4, height: 4)).fill()
            }
        }

        // Keyboard column
        for p in max(0, lowPitch)...min(127, topPitch) {
            let ry = y(pitch: p)
            let black = [1, 3, 6, 8, 10].contains(p % 12)
            (black ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
            CGRect(x: 0, y: ry, width: black ? keyWidth * 0.62 : keyWidth, height: rowHeight).fill()
            NSColor(white: 0.6, alpha: 0.5).setFill()
            CGRect(x: 0, y: ry + rowHeight - 0.5, width: keyWidth, height: 0.5).fill()
            if p % 12 == 0 {
                NSString(string: "C\(p / 12 - 1)").draw(at: CGPoint(x: keyWidth - 22, y: ry), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray])
            }
        }
        Theme.ns(Theme.surfaceRaised).setFill()
        CGRect(x: 0, y: 0, width: keyWidth, height: rollTop).fill()

        // Playhead from the audio clock
        let px = x(us: playheadUs)
        if px >= keyWidth {
            Theme.ns(Theme.accent).setFill()
            CGRect(x: px - 0.75, y: 0, width: 1.5, height: b.height).fill()
        }
        _ = ctx
    }

    // MARK: Mouse

    private func hitNote(_ p: CGPoint) -> (MidiNote, DragMode)? {
        guard let c = controller else { return nil }
        for n in c.notes.reversed() {
            let r = noteRect(n)
            guard r.insetBy(dx: -2, dy: 0).contains(p) else { continue }
            let edge = min(6, r.width / 3)
            if p.x <= r.minX + edge { return (n, .resizeStart) }
            if p.x >= r.maxX - edge { return (n, .resizeEnd) }
            return (n, .move)
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragOrigin = p
        if p.y < rulerHeight + waveHeight && p.x > keyWidth {
            // Ruler/wave: click seeks, drag sets a loop range.
            dragMode = .seek
            loopAnchorUs = max(0, us(x: p.x))
            return
        }
        if p.x < keyWidth {
            let pt = pitch(y: p.y); instrumentPreview?(pt); lastPreviewPitch = pt; dragMode = .none; return
        }
        if let (n, mode) = hitNote(p) {
            if event.modifierFlags.contains(.shift) {
                if c.selected.contains(n.id) { c.selected.remove(n.id) } else { c.selected.insert(n.id) }
            } else if !c.selected.contains(n.id) { c.selected = [n.id] }
            c.beginCommand()
            dragMode = mode; dragNote = n.id; dragOriginal = n
            dragOriginals = Dictionary(uniqueKeysWithValues: c.notes.filter { c.selected.contains($0.id) }.map { ($0.id, $0) })
            instrumentPreview?(n.pitch); lastPreviewPitch = n.pitch
            needsDisplay = true
            return
        }
        if event.clickCount == 2 {
            // Create a missing note at the click, snapped if snapping is on.
            let start = c.snap(us(x: p.x))
            let len = c.grid.map { Int64($0.beatUs / Double(max(1, c.snapDivision == 0 ? 2 : c.snapDivision))) } ?? 250_000
            let id = c.add(pitch: pitch(y: p.y), startUs: start, durationUs: len)
            if let n = c.notes.first(where: { $0.id == id }) { instrumentPreview?(n.pitch); lastPreviewPitch = n.pitch }
            needsDisplay = true
            return
        }
        c.selected = []
        dragMode = .none
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .seek, .loop:
            if abs(p.x - dragOrigin.x) > 3 {
                dragMode = .loop
                let a = loopAnchorUs, b2 = max(0, us(x: p.x))
                c.loop = min(a, b2)..<max(a, b2) + 1
                onLoop?(c.loop)
                needsDisplay = true
            }
        case .move:
            guard let o = dragOriginal else { return }
            let dUs = us(x: p.x) - us(x: dragOrigin.x)
            let dPitch = pitch(y: p.y) - pitch(y: dragOrigin.y)
            for (id, orig) in dragOriginals {
                c.update(id) { n in
                    let dur = orig.durationUs
                    var start = orig.startUs + dUs
                    if c.snapDivision > 0, id == o.id { start = c.snap(start) }
                    else if c.snapDivision > 0 { start = orig.startUs + (c.snap(o.startUs + dUs) - o.startUs) }
                    n.startUs = max(0, start)
                    n.endUs = n.startUs + dur
                    n.pitch = min(127, max(0, orig.pitch + dPitch))
                }
            }
            let newPitch = min(127, max(0, o.pitch + dPitch))
            if newPitch != lastPreviewPitch { stopPreview?(); instrumentPreview?(newPitch); lastPreviewPitch = newPitch }
        case .resizeStart:
            guard let id = dragNote, let o = dragOriginal else { return }
            c.update(id) { n in n.startUs = min(n.endUs - 5_000, max(0, c.snap(o.startUs + us(x: p.x) - us(x: dragOrigin.x)))) }
        case .resizeEnd:
            guard let id = dragNote, let o = dragOriginal else { return }
            c.update(id) { n in n.endUs = max(n.startUs + 5_000, c.snap(o.endUs + us(x: p.x) - us(x: dragOrigin.x))) }
        case .none: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let c = controller else { return }
        stopPreview?()
        lastPreviewPitch = nil
        switch dragMode {
        case .seek: onSeek?(loopAnchorUs)
        case .move, .resizeStart, .resizeEnd:
            let moved = dragOriginals.contains { id, o in c.notes.first { $0.id == id } != o } ||
                (dragNote.flatMap { id in c.notes.first { $0.id == id } } != dragOriginal)
            if moved { c.commit() } else { c.undoStackDropLast() }
        default: break
        }
        dragMode = .none; dragNote = nil; dragOriginal = nil; dragOriginals = [:]
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let anchor = convert(event.locationInWindow, from: nil)
            let aUs = us(x: anchor.x)
            pxPerSecond = min(2000, max(10, pxPerSecond * (1 + event.scrollingDeltaY * 0.01)))
            timeOffsetUs = aUs - Int64(Double((anchor.x - keyWidth) / pxPerSecond) * 1_000_000)
        } else {
            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 10
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            if abs(dx) > abs(dy) || event.modifierFlags.contains(.shift) {
                let d = event.modifierFlags.contains(.shift) ? dy : dx
                timeOffsetUs -= Int64(Double(d / pxPerSecond) * 1_000_000)
                followPlayhead = false
            } else {
                topPitch = min(127, max(20, topPitch + Int((dy / rowHeight).rounded())))
            }
        }
        timeOffsetUs = max(-500_000, timeOffsetUs)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        let aUs = us(x: anchor.x)
        pxPerSecond = min(2000, max(10, pxPerSecond * (1 + event.magnification)))
        timeOffsetUs = aUs - Int64(Double((anchor.x - keyWidth) / pxPerSecond) * 1_000_000)
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return }
        let fine = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 51, 117: c.deleteSelected() // delete, forward delete
        case 126: c.transposeSelected(event.modifierFlags.contains(.shift) ? 12 : 1) // up
        case 125: c.transposeSelected(event.modifierFlags.contains(.shift) ? -12 : -1) // down
        case 123: c.nudgeSelected(fine ? -10_000 : -c.snapStepUs) // left
        case 124: c.nudgeSelected(fine ? 10_000 : c.snapStepUs) // right
        case 49: NotificationCenter.default.post(name: .togglePlayback, object: nil) // space
        case 53: stopPreview?(); c.selected = [] // esc
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
                if event.modifierFlags.contains(.shift) { c.redo() } else { c.undo() }
            } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
                c.selected = Set(c.notes.map(\.id))
            } else { super.keyDown(with: event) }
        }
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool { stopPreview?(); return true }

    func scrollToFit(durationUs: Int64) {
        let w = max(200, bounds.width - keyWidth)
        pxPerSecond = max(10, min(600, w / CGFloat(max(1, Double(durationUs) / 1_000_000))))
        timeOffsetUs = 0
        if let c = controller, !c.notes.isEmpty {
            let pitches = c.notes.map(\.pitch)
            let mid = (pitches.min()! + pitches.max()!) / 2
            let rows = Int((bounds.height - rollTop) / rowHeight)
            topPitch = min(127, mid + rows / 2)
        }
        needsDisplay = true
    }

    func follow(_ us: Int64) {
        guard followPlayhead else { return }
        let px = x(us: us)
        if px > bounds.maxX - 40 || px < keyWidth {
            timeOffsetUs = us - Int64(Double(40 / pxPerSecond) * 1_000_000)
        }
    }
}

extension MidiEditorController {
    /// Drops the snapshot taken for a click that didn't change anything.
    func undoStackDropLast() { _ = popUndoForNoop() }
}

struct MidiEditorRepresentable: NSViewRepresentable {
    var controller: MidiEditorController
    var peaks: WaveformPeaks?
    var playheadUs: Int64
    var isPlaying: Bool
    var fitToken: Int
    var onSeek: (Int64) -> Void
    var onLoop: (Range<Int64>?) -> Void

    func makeNSView(context: Context) -> MidiEditorNSView {
        let v = MidiEditorNSView()
        v.controller = controller
        v.instrumentPreview = { AudioEngine.shared.preview(pitch: $0) }
        v.stopPreview = { AudioEngine.shared.stopPreview() }
        return v
    }

    func updateNSView(_ v: MidiEditorNSView, context: Context) {
        v.controller = controller
        v.peaks = peaks
        v.onSeek = onSeek
        v.onLoop = onLoop
        if isPlaying { v.follow(playheadUs) } else { v.followPlayhead = true }
        v.playheadUs = playheadUs
        if context.coordinator.fit != fitToken {
            context.coordinator.fit = fitToken
            if v.bounds.width > 200 { v.scrollToFit(durationUs: controller.durationUs) } else { v.pendingFit = true; v.needsLayout = true }
        }
        _ = controller.version
        v.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var fit = 0 }
}
