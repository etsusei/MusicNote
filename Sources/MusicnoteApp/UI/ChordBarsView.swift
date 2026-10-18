import AppKit
import MusicnoteCore
import SwiftUI

private struct CellFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Bars in rows of four; each chord placed at its beat and sized by its length. With `edit`,
/// chords are edited directly: drag to move (a snapped ghost shows where it lands), drag an
/// edge to change the length (across bar lines too), click empty time to add, double-click to
/// rename. Covered time is given up to the dragged chord.
struct BarProgressionView: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var harmony: HarmonyRevision
    var auto: AutoHarmony?
    var grid: BeatGrid
    typealias Edit = (inout HarmonyEdit.State, BeatGrid, KeySignature?) throws -> Void
    var edit: ((Edit) -> Void)? = nil
    var undo: (() -> Void)? = nil
    var undoCount = 0
    /// Notes to play chords from (the draft's, when edits rewrote voicings).
    var notes: [MidiNote]? = nil

    @AppStorage("foldPushes") private var foldPushes = true
    @ViewState private var selected: String?
    @ViewState private var hovered: String?
    @ViewState private var plus: (bar: Int, us: Int64)?
    @ViewState private var drag: DragState?
    @ViewState private var frames: [Int: CGRect] = [:]
    @ViewState private var minBars = 0
    @ViewState private var lastClick: (id: String, at: Date)?
    @ViewState private var renaming: String?
    @ViewState private var pendingAdd: (start: Int64, end: Int64)?
    @ViewState private var nameText = ""
    /// Where the name popover points: the bar and the position across it.
    @ViewState private var popoverAt: (bar: Int, x: CGFloat)?

    struct DragState {
        enum Kind { case move, left, right }
        var id: String
        var kind: Kind
        var grabOffset: Int64
        var ghost: (start: Int64, end: Int64)
        var moved = false
    }

    private var editable: Bool { edit != nil }
    private let edgeWidth: CGFloat = 6
    private var perBarUs: Double { grid.beatUs * grid.meter.quarterBeatsPerBar }
    private var eighthUs: Int64 { Int64(grid.beatUs / 2) }

    // MARK: Layout

    /// Chords as read in the bar: anticipations (struck up to an eighth early, held through the
    /// beat) start on the beat they anticipate; a chord touching the next runs to its reading start.
    private var reading: [(ev: ChordEvent, s: Int64, e: Int64, pushed: Bool)] {
        let evs = harmony.events.sorted { $0.startUs < $1.startUs }
        let starts: [(us: Int64, pushed: Bool)] = evs.map { foldPushes ? BarEvidence.readingStart($0.startUs, endUs: $0.endUs, grid: grid) : (us: $0.startUs, pushed: false) }
        return evs.indices.map { i in
            let touching = i + 1 < evs.count && abs(evs[i].endUs - evs[i + 1].startUs) <= 2_000
            return (evs[i], starts[i].us, touching ? starts[i + 1].us : evs[i].endUs, starts[i].pushed)
        }
    }

    private func barOf(_ us: Int64) -> Int { Int(floor((grid.q(atUs: us) - grid.barAnchorQ) / grid.meter.quarterBeatsPerBar)) + 1 }

    /// Bars that hold chords; trailing empty bars drop away, "+" adds one.
    private var chordBars: Int { max(1, barOf((harmony.events.map(\.endUs).max() ?? 1) - 1)) }
    private var barCount: Int { max(chordBars, minBars) }

    var body: some View {
        let bars = barCount
        VStack(alignment: .leading, spacing: 8) {
            if editable { toolbar }
            // Four equal columns; the "+" takes the next slot at full size so every row lines up.
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(stride(from: 1, through: bars + (editable ? 1 : 0), by: 4)), id: \.self) { first in
                    GridRow {
                        ForEach(first..<(first + 4), id: \.self) { slot in
                            if slot <= bars { barCell(slot) }
                            else if slot == bars + 1 && editable { addBarButton }
                            else { Color.clear.gridCellUnsizedAxes(.vertical) }
                        }
                    }
                }
            }
        }
        .coordinateSpace(name: "bars")
        .onPreferenceChange(CellFramesKey.self) { frames = $0 }
        .onChange(of: chordBars) { _, n in if n >= minBars { minBars = 0 } }
    }

    private var addBarButton: some View {
        Button { minBars = barCount + 1 } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                Text("加一小节").font(.system(size: 10))
            }
            .foregroundStyle(Theme.textSecondary.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .buttonStyle(.plain).help("在最后加一个小节")
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            if let ev = harmony.events.first(where: { $0.id == selected }) {
                Text("\(ev.symbol ?? "?") · \(harmony.position(of: ev.startUs, grid: grid))").font(.system(size: 12, weight: .semibold))
                Button("改名") { startRename(ev) }
                Button("删除") { let id = ev.id; selected = nil; edit? { st, g, _ in try HarmonyEdit.delete(&st, id: id, grid: g) } }
                    .disabled(harmony.events.count < 2)
            } else {
                Text("拖和弦移动，拖边缘改长度；空白处点 ＋ 添加；双击改名").foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button { undo?() } label: { Label(undoCount > 0 ? "撤销（\(undoCount)）" : "撤销", systemImage: "arrow.uturn.backward") }
                .disabled(undoCount == 0)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
    }

    // MARK: Pointer → time

    /// Time under a point in the shared space: the row nearest vertically, the cell under x
    /// (or the nearest one in that row), position within the bar.
    private func time(at p: CGPoint) -> Int64? {
        guard let rowY = frames.values.map(\.midY).min(by: { abs($0 - p.y) < abs($1 - p.y) }) else { return nil }
        let row = frames.filter { abs($0.value.midY - rowY) < 1 }.sorted { $0.key < $1.key }
        guard let (bar, f) = row.first(where: { p.x <= $0.value.maxX }) ?? row.last else { return nil }
        let frac = min(1, max(0, Double((p.x - f.minX) / max(1, f.width))))
        return BarEvidence.barStartUs(bar, grid: grid) + Int64(frac * perBarUs)
    }

    private func snap(_ us: Int64) -> Int64 { max(0, HarmonyEdit.snapEighth(us, grid: grid)) }

    // MARK: Cells

    private func barCell(_ bar: Int) -> some View {
        let s = BarEvidence.barStartUs(bar, grid: grid), e = BarEvidence.barStartUs(bar + 1, grid: grid)
        let span = Double(e - s)
        let segs = reading.filter { $0.s < e && $0.e > s }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Button { model.audition(item.id, startUs: max(0, s), endUs: min(item.durationUs, e), original: true) } label: {
                    HStack(spacing: 3) { Text("\(bar)").font(.system(size: 11, weight: .semibold)); Image(systemName: "speaker.wave.2").font(.system(size: 9)) }
                }.buttonStyle(.borderless).foregroundStyle(Theme.textSecondary).help("听原曲第 \(bar) 小节")
                Spacer()
                if editable && bar == barCount && bar > chordBars {
                    // An empty bar added at the end (or left over): remove it.
                    Button { minBars = barCount - 1 <= chordBars ? 0 : barCount - 1 } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(Theme.textSecondary).help("删除这个空小节")
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (us: Int64) -> CGFloat in w * CGFloat(Double(us - s) / span) }
                ZStack(alignment: .topLeading) {
                    if editable { emptyLayer(bar: bar, s: s, e: e, span: span, width: w) }
                    ForEach(1..<Int(grid.meter.quarterBeatsPerBar.rounded()), id: \.self) { b in
                        Rectangle().fill(Theme.borderSubtle).frame(width: 1, height: 6)
                            .offset(x: w * CGFloat(Double(b) / grid.meter.quarterBeatsPerBar), y: geo.size.height - 6)
                            .allowsHitTesting(false)
                    }
                    if let p = plus, p.bar == bar, drag == nil {
                        Image(systemName: "plus.circle").font(.system(size: 13)).foregroundStyle(Theme.accent.opacity(0.55))
                            .offset(x: x(p.us) - 6, y: geo.size.height / 2 - 11).allowsHitTesting(false)
                    }
                    ForEach(segs, id: \.ev.id) { r in
                        let x0 = max(s, r.s), x1 = min(e, r.e)
                        let cw = max(14, x(x1) - x(x0) - 2)
                        let origin = CGPoint(x: (frames[bar]?.minX ?? 0) + x(x0), y: frames[bar]?.minY ?? 0)
                        chip(r.ev, continued: r.s < s - 20_000, endsHere: r.e <= e + 20_000, roomy: cw > 70,
                             pushed: r.pushed && r.s >= s - 20_000, width: cw, origin: origin,
                             anchor: (bar, (x(x0) + cw / 2) / max(1, w)))
                            .frame(width: cw, height: geo.size.height - 8)
                            .offset(x: x(x0))
                            .opacity(drag?.id == r.ev.id && drag?.moved == true ? 0.35 : 1)
                    }
                    if let d = drag, d.moved, d.ghost.start < e, d.ghost.end > s {
                        let g0 = max(s, d.ghost.start), g1 = min(e, d.ghost.end)
                        RoundedRectangle(cornerRadius: 5).fill(Theme.accent.opacity(0.25))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])))
                            .overlay(alignment: .leading) {
                                if d.ghost.start >= s { Text(harmony.events.first { $0.id == d.id }?.symbol ?? "").font(.system(size: 12, weight: .semibold)).padding(.leading, 4) }
                            }
                            .frame(width: max(6, x(g1) - x(g0) - 2), height: geo.size.height - 8)
                            .offset(x: x(g0))
                            .allowsHitTesting(false)
                    }
                }
                .background(GeometryReader { g in Color.clear.preference(key: CellFramesKey.self, value: [bar: g.frame(in: .named("bars"))]) })
            }
            .frame(height: 50)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderSubtle))
        // The name popover points at this bar's edge, under where the "+" or the chord was.
        .popover(isPresented: Binding(get: { popoverAt?.bar == bar && (renaming != nil || pendingAdd != nil) },
                                      set: { if !$0 { renaming = nil; pendingAdd = nil; popoverAt = nil } }),
                 attachmentAnchor: .point(UnitPoint(x: popoverAt?.bar == bar ? popoverAt!.x : 0.5, y: 1)), arrowEdge: .bottom) { namePopover }
    }

    /// Empty time: a faint "+" follows the pointer (snapped); clicking adds a chord there that
    /// runs to the next chord or the end of the bar.
    private func emptyLayer(bar: Int, s: Int64, e: Int64, span: Double, width: CGFloat) -> some View {
        func at(_ x: CGFloat) -> Int64 { snap(s + Int64(Double(x / max(1, width)) * span)) }
        func free(_ t: Int64) -> Bool { !reading.contains { $0.s <= t && $0.e > t } }
        return Rectangle().fill(Color.clear).contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase, drag == nil {
                    let t = at(p.x)
                    plus = free(t) && t < e ? (bar, t) : nil
                } else { plus = nil }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                let t = at(p.x)
                guard free(t), t < e else { return }
                let next = harmony.events.map(\.startUs).filter { $0 > t }.min() ?? e
                let end = min(next, e)
                guard end - t >= eighthUs - 2_000 else { return }
                renaming = nil; nameText = ""; pendingAdd = (t, end)
                popoverAt = (bar, min(1, max(0, p.x / max(1, width))))
            }
    }

    // MARK: Chips

    /// `origin`: this segment's top-left in the shared "bars" space, to turn chip-local pointer
    /// positions into times anywhere in the grid (drags can cross bars).
    @ViewBuilder private func chip(_ ev: ChordEvent, continued: Bool, endsHere: Bool, roomy: Bool, pushed: Bool, width: CGFloat, origin: CGPoint,
                                   anchor: (bar: Int, x: CGFloat)) -> some View {
        let info = auto?.chordInfo[ev.id]
        let strong = info?.role == "backbone" || info?.role == nil
        let confirm = auto?.toConfirm.contains { $0.eventId == ev.id } ?? false
        let isSelected = editable && selected == ev.id
        let isHovered = editable && hovered == ev.id
        let label = HStack(spacing: 2) {
            Text(continued ? "↳" : Self.breakable(ev.symbol ?? "?")).font(.system(size: strong ? 13 : 11, weight: strong ? .semibold : .medium))
                .lineLimit(2).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
            if pushed && !continued { Image(systemName: "arrow.uturn.backward").font(.system(size: 8, weight: .semibold)).opacity(0.7) }
            if ev.manualOverride && editable && !continued && roomy { Image(systemName: "pencil").font(.system(size: 8)).opacity(0.7) }
            if confirm && !continued && roomy { Image(systemName: "questionmark.circle.fill").font(.system(size: 9)).foregroundStyle(Theme.warning) }
        }
        .padding(.horizontal, roomy ? 4 : 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(strong ? Theme.noteFill.opacity(continued ? 0.45 : 1) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSelected ? Theme.accent : (isHovered ? Theme.accent.opacity(0.6) : (confirm ? Theme.warning : Theme.noteFill)),
                                                         style: StrokeStyle(lineWidth: isSelected ? 2.5 : (isHovered ? 1.5 : (confirm ? 1.5 : 1)),
                                                                            dash: strong || isSelected || isHovered ? [] : [3, 2])))
        .foregroundStyle(strong ? Theme.onNote : Theme.textPrimary)
        .help("\(ev.symbol ?? "?")（\(info?.roleDisplay ?? "")）：\(info?.reason ?? "")" + (pushed ? "\n提前一个八分音符按下（按它进入的拍子显示）" : ""))
        if editable {
            label
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let p) = phase {
                        hovered = ev.id; plus = nil
                        let onEdge = (!continued && p.x <= edgeWidth) || (endsHere && p.x >= width - edgeWidth)
                        (onEdge ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    } else { if hovered == ev.id { hovered = nil }; NSCursor.arrow.set() }
                }
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in pointerChanged(ev, v, continued: continued, endsHere: endsHere, width: width, origin: origin) }
                    .onEnded { v in pointerEnded(ev, v, anchor: anchor) })
                .contextMenu {
                    Button("改名…") { selected = ev.id; startRename(ev, at: anchor) }
                    Button("删除", role: .destructive) {
                        let id = ev.id; selected = nil
                        edit? { st, g, _ in try HarmonyEdit.delete(&st, id: id, grid: g) }
                    }.disabled(harmony.events.count < 2)
                }
        } else {
            Button { play(ev) } label: { label }.buttonStyle(.plain)
        }
    }

    /// Press: select and sound at once (no double-click wait). Movement past 3 pt starts a drag:
    /// from an edge it resizes, from the body it moves; the ghost is snapped to eighths.
    private func pointerChanged(_ ev: ChordEvent, _ v: DragGesture.Value, continued: Bool, endsHere: Bool, width: CGFloat, origin: CGPoint) {
        func shared(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x, y: origin.y + p.y) }
        if drag == nil || drag?.id != ev.id {
            let x = v.startLocation.x
            let kind: DragState.Kind = (!continued && x <= edgeWidth) ? .left : (endsHere && x >= width - edgeWidth) ? .right : .move
            var grab: Int64 = 0
            if kind == .move, let t = time(at: shared(v.startLocation)) { grab = t - ev.startUs }
            drag = DragState(id: ev.id, kind: kind, grabOffset: grab, ghost: (ev.startUs, ev.endUs))
            selected = ev.id
            if kind == .move { play(ev) }
        }
        guard var d = drag else { return }
        if hypot(v.translation.width, v.translation.height) > 3 { d.moved = true }
        if d.moved, let t = time(at: shared(v.location)) {
            switch d.kind {
            case .move:
                let st = snap(t - d.grabOffset)
                d.ghost = (st, st + (ev.endUs - ev.startUs))
            case .left: d.ghost = (min(snap(t), ev.endUs - eighthUs), ev.endUs)
            case .right: d.ghost = (ev.startUs, max(snap(t), ev.startUs + eighthUs))
            }
        }
        drag = d
    }

    private func pointerEnded(_ ev: ChordEvent, _ v: DragGesture.Value, anchor: (bar: Int, x: CGFloat)) {
        defer { drag = nil }
        guard let d = drag else { return }
        if d.moved {
            let id = ev.id, ghost = d.ghost
            guard ghost.start != ev.startUs || ghost.end != ev.endUs else { return }
            switch d.kind {
            case .move: edit? { st, g, _ in try HarmonyEdit.move(&st, id: id, toStart: ghost.start, grid: g) }
            case .left: edit? { st, g, _ in try HarmonyEdit.resize(&st, id: id, leftEdge: true, to: ghost.start, grid: g) }
            case .right: edit? { st, g, _ in try HarmonyEdit.resize(&st, id: id, leftEdge: false, to: ghost.end, grid: g) }
            }
            return
        }
        // A click: two on the same chord within 0.35 s rename it.
        if let c = lastClick, c.id == ev.id, Date().timeIntervalSince(c.at) < 0.35 {
            lastClick = nil
            startRename(ev, at: anchor)
        } else {
            lastClick = (ev.id, Date())
        }
    }

    // MARK: Naming

    private func startRename(_ ev: ChordEvent, at anchor: (bar: Int, x: CGFloat)? = nil) {
        nameText = ev.symbol ?? ""; pendingAdd = nil; renaming = ev.id
        if let anchor { popoverAt = anchor; return }
        // From the toolbar: the bar where the chord starts.
        let bar = max(1, barOf(ev.startUs)), s = BarEvidence.barStartUs(bar, grid: grid)
        popoverAt = (bar, CGFloat(min(1, max(0, Double(ev.startUs - s) / perBarUs + 0.1))))
    }

    private var namePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pendingAdd.map { "添加和弦（\(harmony.position(of: $0.start, grid: grid))）" } ?? "改和弦名")
                .font(.system(size: 13, weight: .semibold))
            TextField("如 am7、g7/b、fmaj9（不分大小写）", text: $nameText).textFieldStyle(.roundedBorder).frame(width: 240)
                .onSubmit(commitName)
            let normalized = ChordSymbol.normalizeInput(nameText)
            if !nameText.isEmpty && normalized == nil {
                Text("看不懂这个和弦名").font(.caption12).foregroundStyle(Theme.warning)
            } else if let n = normalized, let p = StandardVoicing.pitches(symbol: n) {
                Text((n != nameText.trimmingCharacters(in: .whitespaces) ? "写成 \(n) · " : "") + "按标准按法写入：" + p.map { Pitch.noteName($0) }.joined(separator: " "))
                    .font(.caption12).foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Spacer()
                Button("取消") { renaming = nil; pendingAdd = nil; popoverAt = nil }
                Button("确定") { commitName() }.buttonStyle(PrimaryButtonStyle()).disabled(ChordSymbol.normalizeInput(nameText) == nil)
            }
        }
        .padding(14)
    }

    private func commitName() {
        guard let name = ChordSymbol.normalizeInput(nameText) else { return }
        // A renamed or added chord sounds as its standard voicing (the MIDI follows the name).
        let voicing = true
        if let r = pendingAdd {
            edit? { st, g, key in
                let id = try HarmonyEdit.add(&st, start: r.start, end: r.end, symbol: name, key: key, grid: g, writeVoicing: voicing)
                Task { @MainActor in selected = id }
            }
        } else if let id = renaming {
            edit? { st, _, key in try HarmonyEdit.rename(&st, id: id, symbol: name, key: key, writeVoicing: voicing) }
        }
        renaming = nil; pendingAdd = nil; popoverAt = nil
    }

    /// Lets a narrow chip wrap a long name before its extension or bass ("Fm" / "(add9)", "A♭maj7" / "/B♭").
    static func breakable(_ symbol: String) -> String {
        symbol.replacingOccurrences(of: "(", with: "\u{200B}(").replacingOccurrences(of: "/", with: "\u{200B}/")
    }

    /// Plays the chord tones as struck; the standard voicing if they don't cover the chord.
    private func play(_ ev: ChordEvent) {
        let rel: [PlayedVoicing.Note] = (notes ?? model.confirmedMidi(item)?.notes ?? []).filter { ev.noteIds.contains($0.id) }.map { n in
            let st = max(n.startUs, ev.startUs)
            return (pitch: n.pitch, start: Double(st - ev.startUs) / 1e6, duration: Double(min(n.endUs, ev.endUs) - st) / 1e6)
        }
        let window = min(0.6, grid.beatUs / 1e6)
        guard let p = PlayedVoicing.pitches(symbol: ev.symbol, notes: rel, onsetWindow: window) ?? ev.symbol.flatMap(StandardVoicing.pitches(symbol:)) else { return }
        AudioEngine.shared.playChord(p, duration: min(2.5, max(0.8, Double(ev.endUs - ev.startUs) / 1e6)))
    }
}
