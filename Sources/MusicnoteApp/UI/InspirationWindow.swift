import AppKit
import MusicnoteCore
import SwiftUI
import UniformTypeIdentifiers

/// The 灵感进行 window: a floating panel that stays above the main window (and can sit beside it
/// or on another screen), so chords can be dragged into it from any page.
@MainActor
final class InspirationWindow: NSObject, NSWindowDelegate {
    static let shared = InspirationWindow()
    private var panel: NSPanel?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { InspirationWindow.shared.isTerminating = true }
        }
    }
    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(_ model: AppModel) {
        if isVisible { panel?.orderOut(nil); UserDefaults.standard.set(false, forKey: Self.openKey) } else { show(model) }
    }

    /// Reopened at launch if it was open when the app quit.
    static let openKey = "inspirationWindowOpen"
    func restore(_ model: AppModel) { if UserDefaults.standard.bool(forKey: Self.openKey) { show(model) } }

    func show(_ model: AppModel) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            p.title = "灵感进行"
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.becomesKeyOnlyIfNeeded = true
            p.minSize = NSSize(width: 480, height: 300)
            p.contentView = NSHostingView(rootView: InspirationPanelView().environment(model))
            p.setFrameAutosaveName("InspirationPanel")
            if !p.setFrameUsingName("InspirationPanel"), let main = NSApp.mainWindow {
                let f = main.frame
                p.setFrameOrigin(NSPoint(x: f.maxX - 680, y: f.minY + 60))
            }
            p.delegate = self
            panel = p
        }
        panel?.orderFront(nil)
        UserDefaults.standard.set(true, forKey: Self.openKey)
        model.dataVersion += 1
    }

    func windowWillClose(_ notification: Notification) {
        // Closed by the user (not by quitting the app).
        if !isTerminating { UserDefaults.standard.set(false, forKey: Self.openKey) }
    }

    var isTerminating = false
}

/// Bottom-right of the main area: opens / closes the 灵感进行 window.
struct InspirationButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let _ = model.dataVersion
        let n = model.workingInspiration.chords.count
        Button { InspirationWindow.shared.toggle(model) } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "lightbulb.max").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                if n > 0 {
                    Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.surface)).offset(x: 6, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .help("灵感进行：把听到喜欢的和弦拖进来拼成进行")
        .padding(18)
    }
}

// MARK: - Window content

struct InspirationPanelView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var transport = TransportModel()
    @ViewState private var confirmNew = false
    @ViewState private var looping = true

    var body: some View {
        let _ = model.dataVersion
        let p = model.workingInspiration
        let playing = model.playingInspiration == p.id && transport.isPlaying
        let q = Double(transport.positionFrame) / AppModel.inspirationRate * max(20, p.bpm) / 60
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("给这条进行起个名字", text: Binding(get: { p.title }, set: { t in model.updateInspiration { $0.title = t } }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Picker("", selection: Binding(get: { p.bars }, set: { n in model.updateInspiration { InspirationEdit.setBars(&$0, n) } })) {
                    Text("4 小节").tag(4); Text("8 小节").tag(8); Text("16 小节").tag(16)
                }.pickerStyle(.segmented).frame(width: 190).labelsHidden()
                HStack(spacing: 2) {
                    Text("BPM").font(.caption12).foregroundStyle(Theme.textSecondary)
                    TextField("", value: Binding(get: { p.bpm }, set: { v in model.updateInspiration { $0.bpm = min(240, max(30, v)) } }), format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).frame(width: 46)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button { playing ? model.stopInspiration() : model.playInspiration(p, loop: looping, transpose: false) } label: {
                    Label(playing ? "停止" : "播放", systemImage: playing ? "stop.fill" : "play.fill")
                }.buttonStyle(SecondaryButtonStyle(compact: true)).disabled(p.chords.isEmpty)
                Toggle(isOn: $looping) { Label("循环", systemImage: "repeat") }.toggleStyle(.button)
                Button { model.undoInspiration() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).disabled(model.inspirationUndo.isEmpty)
                Spacer()
                if p.inCollection {
                    Label("已在灵感集合（自动保存）", systemImage: "checkmark.circle").font(.caption12).foregroundStyle(Theme.success)
                } else {
                    Button("保存到灵感集合") { model.saveInspirationToCollection() }.buttonStyle(PrimaryButtonStyle()).disabled(p.chords.isEmpty)
                }
                Button("新建") { if !p.inCollection && !p.chords.isEmpty { confirmNew = true } else { model.newInspiration() } }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            InspirationBarsView(progression: p, editable: true, playingQ: playing ? q : nil)
            Text(p.chords.isEmpty ? "从完整进行（和弦或小节号）、和弦卡片、笔记和骨架解释里的和弦名拖进来；拖进来的就是你点击时听到的声音。"
                 : "拖和弦移动、拖边缘改长度；空白处点 ＋ 输入和弦名；双击改名；右键删除。")
                .font(.caption12).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 480, minHeight: 300)
        .background(Theme.background)
        .onDisappear { if model.playingInspiration == p.id { model.stopInspiration() } }
        .confirmationDialog("这条灵感进行还没保存", isPresented: $confirmNew) {
            Button("丢掉它，新建", role: .destructive) { model.newInspiration() }
            Button("先保存再新建") { model.saveInspirationToCollection(); model.newInspiration() }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: - Bars

/// Cell frames and the drop ghost, shared by the view and its drop delegate (which holds a copy
/// of the view: a reference keeps both on the same state, so the ghost always clears).
@Observable final class InspirationBarsGeometry {
    var frames: [Int: CGRect] = [:]
    var dropGhost: (start: Double, length: Double)?
}

/// A chord drag in progress (transient: resets by itself when the gesture ends or is cancelled).
struct InspirationDrag: Equatable {
    var id: String
    var kind: Int // 0 move, 1 left edge, 2 right edge
    var grab: Double
    var ghost: (Double, Double)
    var moved: Bool
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.kind == b.kind && a.ghost == b.ghost && a.moved == b.moved }
}

private struct InspirationFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// The progression's bars, four to a row. Editable in the window: chords dragged in from the
/// analysis land where the ghost shows (eighths, or a bar line for a whole bar), and move /
/// resize / add / rename / delete behave like the harmony editor. Read-only in 灵感集合, where
/// names can be shown transposed.
struct InspirationBarsView: View {
    @Environment(AppModel.self) var model
    var progression: InspirationProgression
    var editable: Bool
    /// Playhead in quarter beats (lights the sounding chord).
    var playingQ: Double?
    /// Names to show (transposed in 灵感集合).
    var displayName: ((InspirationChord) -> String)? = nil
    /// Notes a click sounds (transposed in 灵感集合, the same as its playback).
    var soundPitches: ((InspirationChord) -> [Int])? = nil
    var compact = false

    @ViewState private var geo = InspirationBarsGeometry()
    @ViewState private var selected: String?
    @ViewState private var hovered: String?
    @ViewState private var plus: (bar: Int, q: Double)?
    @GestureState private var drag: InspirationDrag?
    private var frames: [Int: CGRect] { geo.frames }
    private var dropGhost: (start: Double, length: Double)? { geo.dropGhost }
    @ViewState private var lastClick: (id: String, at: Date)?
    @ViewState private var naming: (id: String?, start: Double, end: Double, bar: Int, x: CGFloat)?
    @ViewState private var nameText = ""

    private let edge: CGFloat = 6
    private var sounding: String? {
        guard let q = playingQ else { return nil }
        return progression.chords.first { $0.startQ <= q && $0.endQ > q }?.id
    }

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(stride(from: 1, through: progression.bars, by: 4)), id: \.self) { first in
                GridRow { ForEach(first..<(first + 4), id: \.self) { bar in bar <= progression.bars ? AnyView(cell(bar)) : AnyView(Color.clear.gridCellUnsizedAxes(.vertical)) } }
            }
        }
        .coordinateSpace(name: "ibars")
        .onPreferenceChange(InspirationFramesKey.self) { geo.frames = $0 }
        .onDrop(of: [.plainText, .utf8PlainText], delegate: ChordDropDelegate(view: self))
    }

    // MARK: Geometry

    /// Quarter beat under a point in the shared space (row nearest vertically, cell under x).
    func q(at p: CGPoint) -> Double? {
        guard let rowY = frames.values.map(\.midY).min(by: { abs($0 - p.y) < abs($1 - p.y) }) else { return nil }
        let row = frames.filter { abs($0.value.midY - rowY) < 1 }.sorted { $0.key < $1.key }
        guard let (bar, f) = row.first(where: { p.x <= $0.value.maxX }) ?? row.last else { return nil }
        return Double(bar - 1) * 4 + 4 * min(1, max(0, Double((p.x - f.minX) / max(1, f.width))))
    }

    func setDropGhost(_ g: (start: Double, length: Double)?) { geo.dropGhost = g }

    func performDrop(_ payload: ChordDragPayload, at q: Double) {
        let start = payload.wholeBar ? InspirationEdit.snapBar(q) : InspirationEdit.snap(q)
        model.updateInspiration { p in
            if p.chords.isEmpty, let bpm = payload.bpm { p.bpm = bpm.rounded() }
            InspirationEdit.drop(&p, payload.placed, at: start)
        }
        geo.dropGhost = nil
    }

    // MARK: Cells

    private func cell(_ bar: Int) -> some View {
        let s = Double(bar - 1) * 4, e = s + 4
        let chords = progression.chords.filter { $0.startQ < e && $0.endQ > s }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(bar)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (q: Double) -> CGFloat in w * CGFloat((q - s) / 4) }
                ZStack(alignment: .topLeading) {
                    if editable { empty(bar: bar, s: s, e: e, width: w) }
                    ForEach(1..<4, id: \.self) { b in
                        Rectangle().fill(Theme.borderSubtle).frame(width: 1, height: 5).offset(x: w * CGFloat(b) / 4, y: geo.size.height - 5).allowsHitTesting(false)
                    }
                    if let p = plus, p.bar == bar, drag == nil, dropGhost == nil {
                        Image(systemName: "plus.circle").font(.system(size: 12)).foregroundStyle(Theme.accent.opacity(0.55))
                            .offset(x: x(p.q) - 6, y: geo.size.height / 2 - 10).allowsHitTesting(false)
                    }
                    ForEach(chords) { c in
                        let a = max(s, c.startQ), b = min(e, c.endQ)
                        let cw = max(12, x(b) - x(a) - 2)
                        let origin = CGPoint(x: (frames[bar]?.minX ?? 0) + x(a), y: frames[bar]?.minY ?? 0)
                        chip(c, continued: c.startQ < s - 1e-6, endsHere: c.endQ <= e + 1e-6, width: cw, origin: origin, anchor: (bar, (x(a) + cw / 2) / max(1, w)))
                            .frame(width: cw, height: geo.size.height - 7)
                            .offset(x: x(a))
                            .opacity(drag?.id == c.id && drag?.moved == true ? 0.35 : 1)
                    }
                    ghost(s: s, e: e, x: x, height: geo.size.height - 7)
                }
                .background(GeometryReader { g in Color.clear.preference(key: InspirationFramesKey.self, value: [bar: g.frame(in: .named("ibars"))]) })
            }
            .frame(height: compact ? 34 : 44)
        }
        .padding(5)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderSubtle))
        .popover(isPresented: Binding(get: { naming?.bar == bar }, set: { if !$0 { naming = nil } }),
                 attachmentAnchor: .point(UnitPoint(x: naming?.bar == bar ? naming!.x : 0.5, y: 1)), arrowEdge: .bottom) { namePopover }
    }

    @ViewBuilder private func ghost(s: Double, e: Double, x: (Double) -> CGFloat, height: CGFloat) -> some View {
        let g: (Double, Double)? = dropGhost.map { ($0.start, $0.start + $0.length) } ?? (drag?.moved == true ? drag?.ghost : nil)
        if let g, g.0 < e, g.1 > s {
            let a = max(s, g.0), b = min(e, g.1)
            RoundedRectangle(cornerRadius: 5).fill(Theme.accent.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])))
                .frame(width: max(6, x(b) - x(a) - 2), height: height)
                .offset(x: x(a))
                .allowsHitTesting(false)
        }
    }

    private func empty(bar: Int, s: Double, e: Double, width: CGFloat) -> some View {
        func at(_ px: CGFloat) -> Double { InspirationEdit.snap(s + 4 * Double(px / max(1, width))) }
        func free(_ q: Double) -> Bool { !progression.chords.contains { $0.startQ <= q && $0.endQ > q } }
        return Rectangle().fill(Color.clear).contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase, drag == nil { let q = at(p.x); plus = free(q) && q < e ? (bar, q) : nil } else { plus = nil }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                let q = at(p.x)
                guard free(q), q < e else { return }
                let next = progression.chords.map(\.startQ).filter { $0 > q }.min() ?? e
                let end = min(next, e)
                guard end - q >= 0.5 else { return }
                nameText = ""; naming = (nil, q, end, bar, min(1, max(0, p.x / max(1, width))))
            }
    }

    // MARK: Chips

    @ViewBuilder private func chip(_ c: InspirationChord, continued: Bool, endsHere: Bool, width: CGFloat, origin: CGPoint, anchor: (Int, CGFloat)) -> some View {
        let isSounding = sounding == c.id
        let isSelected = editable && selected == c.id
        let isHovered = editable && hovered == c.id
        let label = Text(continued ? "↳" : BarProgressionView.breakable(displayName?(c) ?? c.symbol))
            .font(.system(size: compact ? 11 : 12, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(isSounding ? Theme.accent : Theme.noteFill.opacity(continued ? 0.45 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSelected ? Theme.accent : (isHovered ? Theme.accent.opacity(0.6) : Theme.noteFill), lineWidth: isSelected ? 2.5 : (isHovered ? 1.5 : 1)))
            .shadow(color: isSounding ? Theme.accent.opacity(0.5) : .clear, radius: 6)
            .foregroundStyle(isSounding ? Theme.onAccent : Theme.onNote)
            .help((displayName?(c) ?? c.symbol) + (c.sourceLabel.map { "\n来自 \($0)" } ?? ""))
        if editable {
            label.contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let p) = phase {
                        hovered = c.id; plus = nil
                        ((!continued && p.x <= edge) || (endsHere && p.x >= width - edge) ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    } else { if hovered == c.id { hovered = nil }; NSCursor.arrow.set() }
                }
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($drag) { v, state, _ in
                        let first = state == nil
                        state = track(c, v, from: state, continued: continued, endsHere: endsHere, width: width, origin: origin)
                        if first, let d = state {
                            // Press: select and sound at once.
                            DispatchQueue.main.async { selected = c.id; if d.kind == 0 { AudioEngine.shared.playChord(c.pitches, duration: 1.4) } }
                        }
                    }
                    .onEnded { v in released(c, track(c, v, from: nil, continued: continued, endsHere: endsHere, width: width, origin: origin), anchor: anchor) })
                .contextMenu {
                    Button("改名…") { nameText = c.symbol; naming = (c.id, c.startQ, c.endQ, anchor.0, anchor.1) }
                    Button("删除", role: .destructive) { model.updateInspiration { InspirationEdit.delete(&$0, id: c.id) } }
                }
        } else {
            label.onTapGesture { AudioEngine.shared.playChord(soundPitches?(c) ?? c.pitches, duration: 1.4) }
        }
    }

    /// The drag as of this gesture value: from an edge it resizes, from the body it moves; the
    /// ghost is snapped to eighths. Pure, so the end recomputes the same result.
    private func track(_ c: InspirationChord, _ v: DragGesture.Value, from prev: InspirationDrag?, continued: Bool, endsHere: Bool,
                       width: CGFloat, origin: CGPoint) -> InspirationDrag {
        func shared(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x, y: origin.y + p.y) }
        let x = v.startLocation.x
        let kind = prev?.kind ?? ((!continued && x <= edge) ? 1 : (endsHere && x >= width - edge) ? 2 : 0)
        let grab = prev?.grab ?? (kind == 0 ? (q(at: shared(v.startLocation)) ?? c.startQ) - c.startQ : 0)
        var d = InspirationDrag(id: c.id, kind: kind, grab: grab, ghost: (c.startQ, c.endQ),
                                moved: (prev?.moved ?? false) || hypot(v.translation.width, v.translation.height) > 3)
        if d.moved, let t = q(at: shared(v.location)) {
            switch kind {
            case 0: let a = InspirationEdit.snap(t - grab); d.ghost = (a, a + c.lengthQ)
            case 1: d.ghost = (min(InspirationEdit.snap(t), c.endQ - 0.5), c.endQ)
            default: d.ghost = (c.startQ, max(InspirationEdit.snap(t), c.startQ + 0.5))
            }
        }
        return d
    }

    private func released(_ c: InspirationChord, _ d: InspirationDrag, anchor: (Int, CGFloat)) {
        if d.moved {
            let g = d.ghost
            guard g.0 != c.startQ || g.1 != c.endQ else { return }
            switch d.kind {
            case 0: model.updateInspiration { InspirationEdit.move(&$0, id: c.id, toStart: g.0) }
            case 1: model.updateInspiration { InspirationEdit.resize(&$0, id: c.id, leftEdge: true, to: g.0) }
            default: model.updateInspiration { InspirationEdit.resize(&$0, id: c.id, leftEdge: false, to: g.1) }
            }
            return
        }
        if let lc = lastClick, lc.id == c.id, Date().timeIntervalSince(lc.at) < 0.35 {
            lastClick = nil
            nameText = c.symbol; naming = (c.id, c.startQ, c.endQ, anchor.0, anchor.1)
        } else { lastClick = (c.id, Date()) }
    }

    private var namePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(naming?.id == nil ? "添加和弦" : "改和弦名").font(.system(size: 13, weight: .semibold))
            TextField("如 am7、g7/b（不分大小写）", text: $nameText).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit(commitName)
            let n = ChordSymbol.normalizeInput(nameText)
            if !nameText.isEmpty && n == nil { Text("看不懂这个和弦名").font(.caption12).foregroundStyle(Theme.warning) }
            else if let n, let p = StandardVoicing.pitches(symbol: n) {
                Text("标准按法：" + p.map { Pitch.noteName($0) }.joined(separator: " ")).font(.caption12).foregroundStyle(Theme.textSecondary)
            }
            HStack { Spacer(); Button("取消") { naming = nil }; Button("确定") { commitName() }.buttonStyle(PrimaryButtonStyle()).disabled(n == nil) }
        }
        .padding(14)
    }

    private func commitName() {
        guard let n = ChordSymbol.normalizeInput(nameText), let k = naming else { return }
        if let id = k.id { model.updateInspiration { InspirationEdit.rename(&$0, id: id, symbol: n) } }
        else { model.updateInspiration { _ = InspirationEdit.add(&$0, symbol: n, start: k.start, end: k.end) } }
        naming = nil
    }
}

/// Drops of chords dragged from the analysis: a ghost follows the pointer, snapped to eighths (or
/// to a bar line for a whole bar), sized like what is being dragged.
private struct ChordDropDelegate: DropDelegate {
    let view: InspirationBarsView

    func validateDrop(info: DropInfo) -> Bool { view.editable && info.hasItemsConforming(to: [.plainText, .utf8PlainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard view.editable else { return DropProposal(operation: .forbidden) }
        let payload = view.model.currentChordDrag
        if let q = view.q(at: info.location) {
            let start = payload?.wholeBar == true ? InspirationEdit.snapBar(q) : InspirationEdit.snap(q)
            view.setDropGhost((start, payload?.lengthQ ?? 1))
        }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { view.setDropGhost(nil) }
    func dropEntered(info: DropInfo) {}

    func performDrop(info: DropInfo) -> Bool {
        defer { view.setDropGhost(nil) }
        guard let q = view.q(at: info.location) else { return false }
        if let payload = view.model.currentChordDrag {
            view.performDrop(payload, at: q)
            view.model.activeChordDrag = nil
            return true
        }
        // Fallback: read the dragged text.
        guard let provider = info.itemProviders(for: [.plainText, .utf8PlainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let payload = ChordDragPayload.decode(s) else { return }
            Task { @MainActor in view.performDrop(payload, at: q) }
        }
        return true
    }
}
