import AppKit
import MusicnoteCore
import SwiftUI

/// A chord shown in the lane between the audio and the piano roll.
struct ChordSpan: Hashable {
    var id: String
    var startUs: Int64
    var endUs: Int64
    var symbol: String
    /// Saved analysis (editable) vs. a live preview while proofreading.
    var editable: Bool
}

/// Audio waveform, chord lane and piano roll on one shared time axis, with bar lines.
final class MidiEditorNSView: NSView {
    weak var controller: MidiEditorController?
    var peaks: WaveformPeaks?
    var chords: [ChordSpan] = []
    var playheadUs: Int64 = 0 { didSet { if oldValue != playheadUs { needsDisplay = true } } }
    var onSeek: ((Int64) -> Void)?
    var onLoop: ((Range<Int64>?) -> Void)?
    var onChordBoundary: ((String, String, Int64) -> Void)?
    var onChordRename: ((String, String) -> Void)?
    var onChordMerge: ((String) -> Void)?
    var onChordSplit: ((String, Int64) -> Void)?
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
    let rulerHeight: CGFloat = 24
    let waveHeight: CGFloat = 84
    let chordHeight: CGFloat = 30

    private enum DragMode { case none, move, resizeStart, resizeEnd, loop, seek, marquee, chordBoundary(String, String) }
    private var dragMode = DragMode.none
    private var dragNote: UUID?
    private var dragOrigin: CGPoint = .zero
    private var dragOriginal: MidiNote?
    private var dragOriginals: [UUID: MidiNote] = [:]
    private var lastPreviewPitch: Int?
    private var loopAnchorUs: Int64 = 0
    private var marquee: CGRect?
    private var marqueeBase: Set<UUID> = []
    private var boundaryPreviewUs: Int64?
    private var selectedChord: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true // never draw over neighbouring views when scrolled
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        if pendingFit, bounds.width > 200, bounds.height > 200, let c = controller {
            pendingFit = false
            scrollToFit(durationUs: c.durationUs)
        }
    }

    // MARK: Geometry

    private var waveTop: CGFloat { rulerHeight }
    private var chordTop: CGFloat { rulerHeight + waveHeight }
    private var rollTop: CGFloat { rulerHeight + waveHeight + chordHeight }
    func x(us: Int64) -> CGFloat { keyWidth + CGFloat(Double(us - timeOffsetUs) / 1_000_000) * pxPerSecond }
    func us(x: CGFloat) -> Int64 { timeOffsetUs + Int64(Double((x - keyWidth) / pxPerSecond) * 1_000_000) }
    func y(pitch: Int) -> CGFloat { rollTop + CGFloat(topPitch - pitch) * rowHeight }
    func pitch(y: CGFloat) -> Int { topPitch - Int(floor((y - rollTop) / rowHeight)) }

    func noteRect(_ n: MidiNote) -> CGRect {
        CGRect(x: x(us: n.startUs), y: y(pitch: n.pitch) + 1, width: max(3, x(us: n.endUs) - x(us: n.startUs)), height: rowHeight - 2)
    }

    private func clampOffset() {
        guard let c = controller else { return }
        let visible = Int64(Double((bounds.width - keyWidth) / pxPerSecond) * 1_000_000)
        timeOffsetUs = min(max(0, timeOffsetUs), max(0, c.durationUs - visible / 2))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let c = controller, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        Theme.ns(Theme.background).setFill(); b.fill()
        let content = CGRect(x: keyWidth, y: 0, width: b.width - keyWidth, height: b.height)
        let lowPitch = pitch(y: b.maxY)

        ctx.saveGState()
        ctx.clip(to: content)

        // Roll rows
        for p in max(0, lowPitch)...min(127, topPitch) {
            let ry = y(pitch: p)
            let black = [1, 3, 6, 8, 10].contains(p % 12)
            (black ? Theme.ns(Theme.borderSubtle).withAlphaComponent(0.35) : Theme.ns(Theme.surface)).setFill()
            CGRect(x: keyWidth, y: ry, width: content.width, height: rowHeight).fill()
            if p % 12 == 0 {
                Theme.ns(Theme.borderSubtle).setFill()
                CGRect(x: keyWidth, y: ry + rowHeight - 0.5, width: content.width, height: 0.5).fill()
            }
        }
        // Lanes
        Theme.ns(Theme.surfaceRaised).setFill(); CGRect(x: keyWidth, y: 0, width: content.width, height: rulerHeight).fill()
        Theme.ns(Theme.surface).setFill(); CGRect(x: keyWidth, y: waveTop, width: content.width, height: waveHeight).fill()
        Theme.ns(Theme.background).setFill(); CGRect(x: keyWidth, y: chordTop, width: content.width, height: chordHeight).fill()

        if let loop = c.loop {
            Theme.ns(Theme.selectionFill).setFill()
            CGRect(x: x(us: loop.lowerBound), y: 0, width: x(us: loop.upperBound) - x(us: loop.lowerBound), height: rulerHeight).fill()
        }

        drawGrid(c, content: content)
        drawWave(content: content)
        drawChords(content: content)
        drawNotes(c, lowPitch: lowPitch)

        if let m = marquee {
            Theme.ns(Theme.accent).withAlphaComponent(0.12).setFill(); m.fill()
            Theme.ns(Theme.accent).setStroke(); NSBezierPath(rect: m).stroke()
        }
        // Playhead from the audio clock
        let px = x(us: playheadUs)
        Theme.ns(Theme.accent).setFill()
        CGRect(x: px - 0.75, y: 0, width: 1.5, height: b.height).fill()
        ctx.restoreGState()

        // Lane separators
        Theme.ns(Theme.borderSubtle).setFill()
        for yy in [waveTop, chordTop, rollTop - 1] { CGRect(x: 0, y: yy, width: b.width, height: 1).fill() }

        drawKeys(lowPitch: lowPitch)
    }

    private func drawGrid(_ c: MidiEditorController, content: CGRect) {
        let b = bounds
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                    .foregroundColor: Theme.ns(Theme.textSecondary)]
        let barFont: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                      .foregroundColor: Theme.ns(Theme.textPrimary)]
        guard let g = c.grid else { return }
        let startUs = us(x: keyWidth), endUs = us(x: b.maxX)
        let perBar = g.meter.quarterBeatsPerBar
        let showEighths = pxPerSecond * CGFloat(g.beatUs / 1_000_000) > 40
        var q = floor(g.q(atUs: startUs))
        while true {
            let t = g.us(atQ: q)
            if t > endUs { break }
            let gx = x(us: t)
            let barPos = (q - g.barAnchorQ) / perBar
            let isBar = abs(barPos - barPos.rounded()) < 1e-6
            if isBar {
                Theme.ns(Theme.textPrimary).withAlphaComponent(0.45).setFill()
                CGRect(x: gx, y: 0, width: 1.2, height: b.height).fill()
                NSString(string: "\(Int(barPos.rounded()) + 1)").draw(at: CGPoint(x: gx + 3, y: 1), withAttributes: barFont)
            } else {
                Theme.ns(Theme.controlBorder).withAlphaComponent(0.22).setFill()
                CGRect(x: gx, y: rulerHeight * 0.55, width: 0.6, height: b.height).fill()
            }
            if showEighths || c.snapDivision > 1 {
                let div = max(2, c.snapDivision)
                for k in 1..<div {
                    let sx = x(us: g.us(atQ: q + Double(k) / Double(div)))
                    Theme.ns(Theme.controlBorder).withAlphaComponent(0.08).setFill()
                    CGRect(x: sx, y: rollTop, width: 0.5, height: b.height - rollTop).fill()
                }
            }
            q += 1
        }
        // Seconds, small, along the bottom of the ruler
        let step = pxPerSecond > 200 ? 0.5 : (pxPerSecond > 60 ? 1.0 : 5.0)
        var s = floor(Double(timeOffsetUs) / 1_000_000 / step) * step
        while true {
            let rx = x(us: Int64(s * 1_000_000))
            if rx > b.maxX { break }
            NSString(string: String(format: "%.1fs", s)).draw(at: CGPoint(x: rx + 2, y: rulerHeight - 11), withAttributes: small)
            s += step
        }
        _ = content
    }

    private func drawWave(content: CGRect) {
        guard let peaks else { return }
        let b = bounds
        let startUs = max(0, us(x: keyWidth))
        let startF = Int64(Double(startUs) / 1_000_000 * peaks.sampleRate)
        let endF = Int64(Double(us(x: b.maxX)) / 1_000_000 * peaks.sampleRate)
        let x0 = x(us: startUs)
        let cols = Int(b.maxX - x0)
        guard cols > 0, endF > startF else { return }
        let data = peaks.columns(cols, startFrame: startF, endFrame: endF)
        let mid = waveTop + waveHeight / 2
        Theme.ns(Theme.textSecondary).withAlphaComponent(0.7).setFill()
        for (i, (lo, hi)) in data.enumerated() {
            let top = mid - CGFloat(min(1, hi)) * waveHeight * 0.46
            let bot = mid - CGFloat(max(-1, lo)) * waveHeight * 0.46
            CGRect(x: x0 + CGFloat(i), y: top, width: 1, height: max(1, bot - top)).fill()
        }
    }

    private func drawChords(content: CGRect) {
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                    .foregroundColor: Theme.ns(Theme.onNote)]
        let preview: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                      .foregroundColor: Theme.ns(Theme.textPrimary)]
        for (i, ch) in chords.enumerated() {
            var s = ch.startUs, e = ch.endUs
            if case .chordBoundary(let l, let r) = dragMode, let p = boundaryPreviewUs {
                if ch.id == l { e = p }
                if ch.id == r { s = p }
            }
            let r = CGRect(x: x(us: s) + 1, y: chordTop + 3, width: max(2, x(us: e) - x(us: s) - 2), height: chordHeight - 6)
            guard r.maxX >= keyWidth, r.minX <= bounds.maxX else { continue }
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            if ch.editable {
                (i % 2 == 0 ? Theme.ns(Theme.noteFill) : Theme.ns(Theme.noteFill).withAlphaComponent(0.8)).setFill()
                path.fill()
                if selectedChord == ch.id { Theme.ns(Theme.accent).setStroke(); path.lineWidth = 2; path.stroke() }
            } else {
                Theme.ns(Theme.selectionFill).setFill(); path.fill()
                Theme.ns(Theme.controlBorder).withAlphaComponent(0.5).setStroke()
                path.setLineDash([3, 2], count: 2, phase: 0); path.lineWidth = 1; path.stroke()
            }
            // Label clipped to its block; a smaller font when it doesn't fit.
            var attrs = ch.editable ? label : preview
            let text = NSString(string: ch.symbol)
            if text.size(withAttributes: attrs).width + 8 > r.width { attrs[.font] = NSFont.systemFont(ofSize: 10, weight: .semibold) }
            let size = text.size(withAttributes: attrs)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r.insetBy(dx: 2, dy: 0)).addClip()
            text.draw(at: CGPoint(x: max(r.minX + 3, keyWidth + 3), y: r.midY - size.height / 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawNotes(_ c: MidiEditorController, lowPitch: Int) {
        let visStart = us(x: keyWidth) - 10_000_000, visEnd = us(x: bounds.maxX)
        for n in c.notes where n.endUs >= visStart && n.startUs <= visEnd && n.pitch <= topPitch + 1 && n.pitch >= lowPitch - 1 {
            let r = noteRect(n)
            let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            Theme.ns(Theme.noteFill).setFill(); path.fill()
            if c.selected.contains(n.id) { Theme.ns(Theme.accent).setStroke(); path.lineWidth = 2; path.stroke() }
            if n.edited {
                Theme.ns(Theme.onNote).setFill()
                CGRect(x: r.minX + 2, y: r.midY - 1, width: 3, height: 2).fill()
            }
            if playheadUs >= n.startUs && playheadUs < n.endUs {
                Theme.ns(Theme.onNote).setFill()
                NSBezierPath(ovalIn: CGRect(x: r.maxX - 6, y: r.midY - 2, width: 4, height: 4)).fill()
            }
        }
    }

    private func drawKeys(lowPitch: Int) {
        for p in max(0, lowPitch)...min(127, topPitch) {
            let ry = y(pitch: p)
            guard ry + rowHeight > rollTop else { continue }
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
        let lab: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: Theme.ns(Theme.textSecondary)]
        NSString(string: "小节").draw(at: CGPoint(x: 6, y: 5), withAttributes: lab)
        NSString(string: "音频").draw(at: CGPoint(x: 6, y: waveTop + waveHeight / 2 - 7), withAttributes: lab)
        NSString(string: "和弦").draw(at: CGPoint(x: 6, y: chordTop + chordHeight / 2 - 7), withAttributes: lab)
    }

    // MARK: Hit testing

    private func hitNote(_ p: CGPoint) -> (MidiNote, DragMode)? {
        guard let c = controller, p.y >= rollTop else { return nil }
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

    private func chord(at p: CGPoint) -> ChordSpan? {
        guard p.y >= chordTop, p.y < rollTop else { return nil }
        let t = us(x: p.x)
        return chords.first { t >= $0.startUs && t < $0.endUs }
    }

    /// A draggable boundary between two adjacent editable chords near x.
    private func boundary(at p: CGPoint) -> (ChordSpan, ChordSpan)? {
        guard p.y >= chordTop, p.y < rollTop else { return nil }
        for i in 0..<max(0, chords.count - 1) {
            let a = chords[i], b = chords[i + 1]
            guard a.editable, b.editable, b.startUs - a.endUs < 150_000 else { continue }
            if abs(p.x - x(us: b.startUs)) <= 5 || abs(p.x - x(us: a.endUs)) <= 5 { return (a, b) }
        }
        return nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for i in 0..<max(0, chords.count - 1) where chords[i].editable && chords[i + 1].editable {
            let bx = x(us: chords[i + 1].startUs)
            addCursorRect(CGRect(x: bx - 4, y: chordTop, width: 8, height: chordHeight), cursor: .resizeLeftRight)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragOrigin = p
        if p.x < keyWidth {
            if p.y >= rollTop { let pt = pitch(y: p.y); instrumentPreview?(pt); lastPreviewPitch = pt }
            dragMode = .none; return
        }
        if p.y < chordTop {
            // Ruler/wave: click seeks, drag sets a loop range.
            dragMode = .seek
            loopAnchorUs = max(0, us(x: p.x))
            return
        }
        if p.y < rollTop {
            if let (a, b) = boundary(at: p) { dragMode = .chordBoundary(a.id, b.id); boundaryPreviewUs = b.startUs; return }
            if let ch = chord(at: p) {
                selectedChord = ch.id
                // Select the notes struck inside this chord, to check or move them together.
                c.selected = Set(c.notes.filter { $0.startUs >= ch.startUs - 20_000 && $0.startUs < ch.endUs }.map(\.id))
                if event.clickCount == 2, ch.editable { rename(ch) }
            }
            dragMode = .none
            needsDisplay = true
            return
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
        // Empty roll: start a marquee selection (shift adds to the current selection).
        marqueeBase = event.modifierFlags.contains(.shift) ? c.selected : []
        if !event.modifierFlags.contains(.shift) { c.selected = [] }
        selectedChord = nil
        dragMode = .marquee
        marquee = CGRect(origin: p, size: .zero)
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
            }
        case .marquee:
            let r = CGRect(x: min(p.x, dragOrigin.x), y: min(p.y, dragOrigin.y), width: abs(p.x - dragOrigin.x), height: abs(p.y - dragOrigin.y))
            marquee = r
            c.selected = marqueeBase.union(c.notes.filter { noteRect($0).intersects(r) }.map(\.id))
        case .chordBoundary(let l, let r):
            guard let a = chords.first(where: { $0.id == l }), let b = chords.first(where: { $0.id == r }) else { break }
            var t = us(x: p.x)
            if let g = c.grid { t = g.snap(us: t, division: 2) } // eighth-note grid
            boundaryPreviewUs = min(max(t, a.startUs + 20_000), b.endUs - 20_000)
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
        case .chordBoundary(let l, let r):
            if let t = boundaryPreviewUs, let b = chords.first(where: { $0.id == r }), abs(t - b.startUs) > 1_000 { onChordBoundary?(l, r, t) }
        default: break
        }
        dragMode = .none; dragNote = nil; dragOriginal = nil; dragOriginals = [:]; marquee = nil; boundaryPreviewUs = nil
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let ch = chord(at: p) else { return nil }
        let menu = NSMenu()
        guard ch.editable else {
            menu.addItem(withTitle: "这是根据当前音符的实时预览；完成校对后可调整", action: nil, keyEquivalent: "")
            return menu
        }
        selectedChord = ch.id
        needsDisplay = true
        menu.addItem(ClosureMenuItem(title: "改名…") { [weak self] in self?.rename(ch) })
        if chords.last?.id != ch.id { menu.addItem(ClosureMenuItem(title: "与下一个合并") { [weak self] in self?.onChordMerge?(ch.id) }) }
        var at = us(x: p.x)
        if let g = controller?.grid { at = g.snap(us: at, division: 2) }
        if at > ch.startUs + 20_000 && at < ch.endUs - 20_000 {
            menu.addItem(ClosureMenuItem(title: "在这里拆分（\(formatTime(us: at))）") { [weak self] in self?.onChordSplit?(ch.id, at) })
        }
        return menu
    }

    private func rename(_ ch: ChordSpan) {
        let alert = NSAlert()
        alert.messageText = "和弦名"
        alert.informativeText = "改名只改和弦名，不会改 MIDI 音符。"
        let field = NSTextField(string: ch.symbol)
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { onChordRename?(ch.id, field.stringValue) }
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
        clampOffset()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        let aUs = us(x: anchor.x)
        pxPerSecond = min(2000, max(10, pxPerSecond * (1 + event.magnification)))
        timeOffsetUs = aUs - Int64(Double((anchor.x - keyWidth) / pxPerSecond) * 1_000_000)
        clampOffset()
        window?.invalidateCursorRects(for: self)
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
        case 53: stopPreview?(); c.selected = []; selectedChord = nil // esc
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
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func follow(_ us: Int64) {
        guard followPlayhead else { return }
        let px = x(us: us)
        if px > bounds.maxX - 40 || px < keyWidth {
            timeOffsetUs = us - Int64(Double(40 / pxPerSecond) * 1_000_000)
            clampOffset()
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
    var chords: [ChordSpan]
    var playheadUs: Int64
    var isPlaying: Bool
    var fitToken: Int
    var onSeek: (Int64) -> Void
    var onLoop: (Range<Int64>?) -> Void
    var onChordBoundary: (String, String, Int64) -> Void
    var onChordRename: (String, String) -> Void
    var onChordMerge: (String) -> Void
    var onChordSplit: (String, Int64) -> Void

    func makeNSView(context: Context) -> MidiEditorNSView {
        let v = MidiEditorNSView(frame: .zero)
        v.controller = controller
        v.instrumentPreview = { AudioEngine.shared.preview(pitch: $0) }
        v.stopPreview = { AudioEngine.shared.stopPreview() }
        return v
    }

    func updateNSView(_ v: MidiEditorNSView, context: Context) {
        v.controller = controller
        v.peaks = peaks
        if v.chords != chords { v.chords = chords; v.window?.invalidateCursorRects(for: v) }
        v.onSeek = onSeek
        v.onLoop = onLoop
        v.onChordBoundary = onChordBoundary
        v.onChordRename = onChordRename
        v.onChordMerge = onChordMerge
        v.onChordSplit = onChordSplit
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
