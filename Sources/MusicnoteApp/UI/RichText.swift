import AppKit
import MusicnoteCore
import SwiftUI

/// Finds chord symbols in prose. Single letters only count inside an explicit
/// progression (with → or -), so ordinary words and "A段" stay text.
enum ChordTextScanner {
    static let pattern = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9])([A-G](?:#|♯|b|♭)?(?:maj|min|mMaj|m|M|dim|aug|sus|add|ø|°|Δ|△|\\+|-)?[0-9]{0,2}(?:[#♯b♭][0-9]{1,2}|sus[24]?|add[0-9]{1,2}|alt)*(?:\\([^)]{1,16}\\))?(?:/[A-G](?:#|♯|b|♭)?)?)(?![A-Za-z0-9])")

    struct Match { var range: NSRange; var symbol: String }

    static func scan(_ text: String) -> [Match] {
        let ns = text as NSString
        var out: [Match] = []
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range(at: 1)
            let s = ns.substring(with: r)
            guard ChordSymbol.parse(s) != nil else { continue }
            if s.count == 1 || (s.count == 2 && (s.hasSuffix("b") || s.hasSuffix("#"))) {
                // Bare roots need a progression context on either side.
                let before = r.location > 0 ? ns.substring(with: NSRange(location: max(0, r.location - 3), length: min(3, r.location))) : ""
                let afterLen = min(3, ns.length - NSMaxRange(r))
                let after = afterLen > 0 ? ns.substring(with: NSRange(location: NSMaxRange(r), length: afterLen)) : ""
                let ctx = before + after
                guard ctx.contains("→") || ctx.contains(" - ") || ctx.contains("–") || ctx.contains("|") else { continue }
            }
            out.append(Match(range: r, symbol: s))
        }
        return out
    }
}

extension NSAttributedString.Key {
    static let chordSymbol = NSAttributedString.Key("musicnote.chord")
    static let chordEvent = NSAttributedString.Key("musicnote.chordEvent")
}

/// Read-only rich text: chords are underlined, hovering shows the chord card,
/// clicking plays it. Supports selection-based highlight/bookmark actions.
final class ChordTextView: NSTextView {
    var onHoverChord: ((String, String?, NSRange, NSRect) -> Void)?
    var onLeaveChord: (() -> Void)?
    var onClickChord: ((String, String?) -> Void)?
    var extraMenu: ((NSRange) -> [NSMenuItem])?
    private var tracking: NSTrackingArea?
    private var hovered: NSRange?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }

    private func chord(at point: NSPoint) -> (String, String?, NSRange)? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let idx = lm.characterIndex(for: p, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard idx < storage.length else { return nil }
        let glyph = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: idx, length: 1), actualCharacterRange: nil), in: tc)
        guard glyph.insetBy(dx: -2, dy: -2).contains(p) else { return nil }
        var range = NSRange()
        guard let sym = storage.attribute(.chordSymbol, at: idx, effectiveRange: &range) as? String else { return nil }
        return (sym, storage.attribute(.chordEvent, at: idx, effectiveRange: nil) as? String, range)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (sym, ev, range) = chord(at: p) {
            NSCursor.pointingHand.set()
            if hovered != range, let lm = layoutManager, let tc = textContainer {
                hovered = range
                // First line only: a name that wraps would otherwise anchor to both lines' union.
                var rect = NSRect.zero
                lm.enumerateEnclosingRects(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                           withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { r, stop in
                    rect = r; stop.pointee = true
                }
                rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
                onHoverChord?(sym, ev, range, rect)
            }
        } else {
            if hovered != nil { hovered = nil; onLeaveChord?() }
            NSCursor.iBeam.set()
        }
    }

    override func mouseExited(with event: NSEvent) { if hovered != nil { hovered = nil; onLeaveChord?() } }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (sym, ev, _) = chord(at: p), event.clickCount == 1 {
            onClickChord?(sym, ev)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let r = selectedRange()
        if r.length > 0, let items = extraMenu?(r), !items.isEmpty {
            menu.insertItem(.separator(), at: 0)
            for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        }
        return menu
    }
}

struct RichTextView: NSViewRepresentable {
    var text: String
    var highlights: [(NSRange, Bool)] = [] // (range, flash)
    var linkedEvents: [String: String] = [:] // symbol → event id (for event-linked voicings)
    var fontSize: CGFloat = 14
    var onHighlight: ((NSRange, Bool) -> Void)? = nil
    @Environment(AppModel.self) private var model

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var popover: NSPopover?
        var eventVoicings: ((String) -> ChordPreviewInput?)?
        var app: AppModel?
        var shownRange: NSRange?
        var onChord = false
        var onCard = false
        private var closeToken = 0

        /// Closes after a short grace period unless the pointer is back on the chord or the card,
        /// so moving from the name onto the card doesn't dismiss it.
        func scheduleClose() {
            closeToken += 1
            let token = closeToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, token == self.closeToken, !self.onChord, !self.onCard else { return }
                self.popover?.close(); self.popover = nil; self.shownRange = nil
            }
        }
        func cancelClose() { closeToken += 1 }
    }

    func makeNSView(context: Context) -> ChordTextView {
        let tv = ChordTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let coord = context.coordinator
        tv.onHoverChord = { [weak tv] sym, ev, range, rect in
            guard let tv else { return }
            coord.onChord = true
            coord.cancelClose()
            if coord.shownRange == range, coord.popover?.isShown == true { return }
            coord.popover?.close()
            let p = NSPopover()
            p.behavior = .semitransient
            p.animates = false
            let input = ev.flatMap { coord.eventVoicings?($0) }
            let host = NSHostingController(rootView: ChordPreviewCard(symbol: sym, original: input?.notes, degree: input?.degree)
                .onHover { [weak coord] inside in
                    guard let coord else { return }
                    coord.onCard = inside
                    if inside { coord.cancelClose() } else { coord.scheduleClose() }
                }
                .environment(coord.app!))
            // Size the card before showing it: AppKit keeps a popover on screen only for the size it
            // knows at show time, and SwiftUI content measured later would spill past the edge.
            let size = host.view.fittingSize
            host.preferredContentSize = size
            p.contentViewController = host
            p.contentSize = size
            // Anchor to the visible part of the name (it may be half scrolled out).
            let anchor = rect.intersection(tv.visibleRect).isEmpty ? rect : rect.intersection(tv.visibleRect)
            // Above the name when the screen has room, otherwise below. Flipped view: minY is the top edge.
            var above = true
            if let window = tv.window, let screen = window.screen ?? NSScreen.main {
                let onScreen = window.convertToScreen(tv.convert(anchor, to: nil))
                let room = screen.visibleFrame.maxY - onScreen.maxY
                above = room >= size.height + 16 || room >= onScreen.minY - screen.visibleFrame.minY
            }
            let top: NSRectEdge = tv.isFlipped ? .minY : .maxY, bottom: NSRectEdge = tv.isFlipped ? .maxY : .minY
            p.show(relativeTo: anchor, of: tv, preferredEdge: above ? top : bottom)
            coord.popover = p
            coord.shownRange = range
        }
        tv.onLeaveChord = { [weak coord] in
            coord?.onChord = false
            coord?.scheduleClose()
        }
        tv.onClickChord = { sym, ev in
            let standard = StandardVoicing.pitches(symbol: sym)
            let played = ev.flatMap { coord.eventVoicings?($0) }.flatMap { PlayedVoicing.pitches(symbol: sym, notes: $0.notes) }
            if let p = played ?? standard { AudioEngine.shared.playChord(p) }
        }
        return tv
    }

    func updateNSView(_ tv: ChordTextView, context: Context) {
        context.coordinator.app = model
        context.coordinator.eventVoicings = { id in model.eventPreview(eventKey: id) }
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: Theme.ns(Theme.textPrimary),
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineSpacing = fontSize * 0.5; return p }(),
        ])
        for m in ChordTextScanner.scan(text) {
            attr.addAttributes([.chordSymbol: m.symbol, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                .underlineColor: Theme.ns(Theme.accent).withAlphaComponent(0.6)], range: m.range)
            if let ev = linkedEvents[m.symbol] { attr.addAttribute(.chordEvent, value: ev, range: m.range) }
        }
        for (r, flash) in highlights where NSMaxRange(r) <= attr.length {
            attr.addAttribute(.backgroundColor, value: Theme.ns(flash ? Theme.selectionFill : Theme.highlight), range: r)
        }
        if tv.textStorage?.isEqual(to: attr) != true { tv.textStorage?.setAttributedString(attr) }
        let onH = onHighlight
        tv.extraMenu = { range in
            guard let onH else { return [] }
            let a = ClosureMenuItem(title: "高亮") { onH(range, false) }
            let b = ClosureMenuItem(title: "收藏到书签") { onH(range, true) }
            return [a, b]
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChordTextView, context: Context) -> CGSize? {
        guard let w = proposal.width, w > 0, let lm = nsView.layoutManager, let tc = nsView.textContainer else { return nil }
        tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height
        return CGSize(width: w, height: ceil(h) + 2)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

struct ChordPreviewInput {
    var notes: [(pitch: Int, start: Double, duration: Double)]
    var degree: String?
}

extension AppModel {
    /// "analysisId|eventId" → that event's actual notes, relative to the event start.
    func eventPreview(eventKey: String) -> ChordPreviewInput? {
        let parts = eventKey.split(separator: "|")
        guard parts.count == 2, let aid = UUID(uuidString: String(parts[0])), let item = item(aid),
              let h = latestHarmony(aid), let ev = h.events.first(where: { $0.id == parts[1] }),
              let midi = confirmedMidi(item) else { return nil }
        let notes = midi.notes.filter { ev.noteIds.contains($0.id) }
        return ChordPreviewInput(notes: notes.map { n in
            let s = max(n.startUs, ev.startUs)
            return (pitch: n.pitch, start: Double(s - ev.startUs) / 1e6, duration: Double(min(n.endUs, ev.endUs) - s) / 1e6)
        }, degree: ev.degree?.display)
    }
}
