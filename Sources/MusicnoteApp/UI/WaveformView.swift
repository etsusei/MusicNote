import AppKit
import MusicnoteCore
import SwiftUI

/// Whole-song waveform with a movable selection. Edges resize independently, the
/// middle moves the selection keeping its length, clicks elsewhere place the cursor.
/// Dragging never triggers analysis.
struct WaveformSelectionView: View {
    var peaks: WaveformPeaks?
    var totalFrames: Int64
    @Binding var selection: Range<Int64>
    var playhead: Int64
    var editable: Bool
    @Binding var viewRange: Range<Int64>
    var beatFrames: [Int64] = []
    var downbeatFrames: Set<Int64> = []
    /// Bar numbers drawn at these frames (selection stage: bar 1 at the selection start).
    var barLabels: [(frame: Int64, number: Int)] = []
    /// Applied to edges while dragging; holding ⌥ drags freely.
    var snap: ((Int64) -> Int64)? = nil
    var onSeek: (Int64) -> Void
    var onCommit: () -> Void

    @ViewState private var drag: DragKind?
    @ViewState private var dragStartSelection: Range<Int64> = 0..<0
    enum DragKind { case left, right, move }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let span = Double(max(viewRange.count, 1))
            let toX = { (f: Int64) -> CGFloat in CGFloat(Double(f - viewRange.lowerBound) / span) * w }
            let toFrame = { (x: CGFloat) -> Int64 in viewRange.lowerBound + Int64(Double(x / w) * span) }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Selection fill
                    let sx = toX(selection.lowerBound), ex = toX(selection.upperBound)
                    ctx.fill(Path(CGRect(x: sx, y: 0, width: max(1, ex - sx), height: size.height)), with: .color(Theme.selectionFill))
                    // Beat grid; weak beats only when they are far enough apart to read.
                    let visible = beatFrames.filter { $0 >= viewRange.lowerBound && $0 < viewRange.upperBound }
                    let spacing = visible.count > 1 ? size.width / CGFloat(visible.count) : size.width
                    for b in visible {
                        let strong = downbeatFrames.contains(b)
                        if !strong && spacing < 6 { continue }
                        if strong && spacing * 4 < 3 { continue }
                        let x = toX(b)
                        ctx.fill(Path(CGRect(x: x, y: 0, width: strong ? 1.5 : 1, height: size.height)),
                                 with: .color(Theme.accent.opacity(strong ? 0.55 : 0.22)))
                    }
                    if !barLabels.isEmpty {
                        let shown = barLabels.filter { $0.frame >= viewRange.lowerBound && $0.frame < viewRange.upperBound }
                        let gap = shown.count > 1 ? size.width / CGFloat(shown.count) : size.width
                        let every = gap >= 22 ? 1 : gap >= 11 ? 2 : gap >= 5 ? 4 : 8
                        for l in shown where (l.number - 1) % every == 0 {
                            ctx.draw(Text("\(l.number)").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent),
                                     at: CGPoint(x: toX(l.frame) + 3, y: 3), anchor: .topLeading)
                        }
                    }
                    // Waveform
                    if let peaks {
                        let cols = Int(size.width)
                        let data = peaks.columns(cols, startFrame: viewRange.lowerBound, endFrame: viewRange.upperBound)
                        var path = Path()
                        let mid = size.height / 2
                        for (i, (lo, hi)) in data.enumerated() {
                            let top = mid - CGFloat(min(1, hi)) * mid * 0.95
                            let bot = mid - CGFloat(max(-1, lo)) * mid * 0.95
                            path.addRect(CGRect(x: CGFloat(i), y: top, width: 1, height: max(1, bot - top)))
                        }
                        ctx.fill(path, with: .color(Theme.textSecondary.opacity(0.75)))
                    }
                    // Selection edges with handles (contour + color)
                    for x in [sx, ex] {
                        ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.accent))
                        let handle = CGRect(x: x - 5, y: size.height / 2 - 14, width: 10, height: 28)
                        ctx.fill(Path(roundedRect: handle, cornerRadius: 3), with: .color(Theme.accent))
                        ctx.stroke(Path(roundedRect: handle, cornerRadius: 3), with: .color(Theme.onAccent), lineWidth: 1)
                    }
                    // Playhead stays above the selection
                    let px = toX(playhead)
                    ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Theme.textPrimary))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let sx = toX(selection.lowerBound), ex = toX(selection.upperBound)
                            if drag == nil {
                                let x = v.startLocation.x
                                if editable && abs(x - sx) <= 10 { drag = .left }
                                else if editable && abs(x - ex) <= 10 { drag = .right }
                                else if editable && x > sx && x < ex && abs(v.translation.width) > 2 { drag = .move }
                                dragStartSelection = selection
                            }
                            let df = Int64(Double(v.translation.width / w) * span)
                            let sn: (Int64) -> Int64 = NSEvent.modifierFlags.contains(.option) ? { $0 } : (snap ?? { $0 })
                            switch drag {
                            case .left:
                                let s = min(max(0, sn(dragStartSelection.lowerBound + df)), selection.upperBound - 1)
                                selection = s..<selection.upperBound
                            case .right:
                                let e = max(min(totalFrames, sn(dragStartSelection.upperBound + df)), selection.lowerBound + 1)
                                selection = selection.lowerBound..<e
                            case .move:
                                let len = dragStartSelection.count
                                // At the file edge the whole selection stops; length is kept. The start snaps,
                                // so a selection of whole bars stays on bar lines.
                                let s = min(max(0, sn(dragStartSelection.lowerBound + df)), totalFrames - Int64(len))
                                selection = s..<(s + Int64(len))
                            case nil: break
                            }
                        }
                        .onEnded { v in
                            if drag == nil { onSeek(max(0, min(totalFrames, toFrame(v.location.x)))) } else { onCommit() }
                            drag = nil
                        }
                )
                .onContinuousHover { phase in
                    guard editable else { return }
                    if case .active(let p) = phase {
                        let sx = toX(selection.lowerBound), ex = toX(selection.upperBound)
                        if abs(p.x - sx) <= 10 || abs(p.x - ex) <= 10 { NSCursor.resizeLeftRight.set() }
                        else if p.x > sx && p.x < ex { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                    } else { NSCursor.arrow.set() }
                }
            }
            .frame(width: w, height: h)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Zoom/scroll controls for a waveform view range. Zoom keeps the current anchor.
struct ZoomBar: View {
    @Binding var viewRange: Range<Int64>
    var totalFrames: Int64
    var anchor: Int64
    var fitRange: Range<Int64>

    var body: some View {
        HStack(spacing: 6) {
            Button { zoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }.help("放大")
            Button { zoom(2) } label: { Image(systemName: "minus.magnifyingglass") }.help("缩小")
            Button("整曲") { viewRange = 0..<max(1, totalFrames) }
            Button("选区") {
                let pad = max(Int64(1), Int64(fitRange.count) / 10)
                viewRange = max(0, fitRange.lowerBound - pad)..<min(totalFrames, fitRange.upperBound + pad)
            }
            Slider(value: Binding(get: {
                let maxStart = Double(max(1, totalFrames - Int64(viewRange.count)))
                return Double(viewRange.lowerBound) / maxStart
            }, set: { v in
                let len = Int64(viewRange.count)
                let s = Int64(v * Double(max(0, totalFrames - len)))
                viewRange = s..<(s + len)
            }), in: 0...1).frame(maxWidth: 240).disabled(viewRange.count >= Int(totalFrames))
        }
        .buttonStyle(.borderless).font(.caption12)
    }

    private func zoom(_ factor: Double) {
        let len = max(Int64(2000), min(totalFrames, Int64(Double(viewRange.count) * factor)))
        let a = min(max(anchor, viewRange.lowerBound), viewRange.upperBound)
        let ratio = Double(a - viewRange.lowerBound) / Double(max(1, viewRange.count))
        var s = a - Int64(Double(len) * ratio)
        s = max(0, min(totalFrames - len, s))
        viewRange = s..<(s + len)
    }
}
