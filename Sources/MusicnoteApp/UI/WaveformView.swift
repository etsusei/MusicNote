import AppKit
import MusicnoteCore
import SwiftUI

/// Whole-song waveform with a movable selection: a zoomable detail view (time ruler, bar
/// lines, selection) over a whole-song overview showing where the detail is. Edges resize
/// independently, the middle moves the selection keeping its length, clicks elsewhere place
/// the cursor. Two-finger swipes zoom (up/down) and pan (sideways); dragging never analyses.
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
    var sampleRate: Double = 44100
    /// While playing, the playhead is drawn at display rate from the engine (smooth), not from `playhead`.
    var isPlaying = false
    var showOverview = true
    var onSeek: (Int64) -> Void
    var onCommit: () -> Void

    @ViewState private var drag: DragKind?
    @ViewState private var dragStartSelection: Range<Int64> = 0..<0
    enum DragKind { case left, right, move }
    private let rulerHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 6) {
            detail
                .trackZoomPan(onZoom: { f, a in
                    viewRange = TrackRange.zoom(viewRange, total: totalFrames, factor: f, anchor: a, minLength: Int64(sampleRate * 0.5))
                }, onPan: { d in viewRange = TrackRange.pan(viewRange, total: totalFrames, fraction: d) })
            if showOverview {
                WaveformOverview(peaks: peaks, totalFrames: totalFrames, selection: selection, playhead: playhead, viewRange: $viewRange)
                    .frame(height: 34)
            }
        }
    }

    private var detail: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let span = Double(max(viewRange.count, 1))
            let toX = { (f: Int64) -> CGFloat in CGFloat(Double(f - viewRange.lowerBound) / span) * w }
            let toFrame = { (x: CGFloat) -> Int64 in viewRange.lowerBound + Int64(Double(x / w) * span) }
            Canvas { ctx, size in
                let top = rulerHeight
                let body = CGRect(x: 0, y: top, width: size.width, height: size.height - top)
                let sx = toX(selection.lowerBound), ex = toX(selection.upperBound)
                let selRect = CGRect(x: sx, y: top, width: max(1, ex - sx), height: body.height)
                ctx.fill(Path(selRect), with: .color(Theme.accent.opacity(0.07)))
                // Ruler
                ctx.fill(Path(CGRect(x: 0, y: top - 0.5, width: size.width, height: 0.5)), with: .color(Theme.borderSubtle))
                let secs = span / sampleRate
                let step = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120].first { Double(size.width) / (secs / $0) >= 64 } ?? 300
                let t0 = Double(viewRange.lowerBound) / sampleRate
                var t = (t0 / step).rounded(.up) * step
                while t * sampleRate < Double(viewRange.upperBound) {
                    let x = toX(Int64(t * sampleRate))
                    ctx.fill(Path(CGRect(x: x, y: top - 5, width: 1, height: 5)), with: .color(Theme.textSecondary.opacity(0.6)))
                    ctx.draw(Text(Self.label(t, step: step)).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundColor(Theme.textSecondary),
                             at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                    t += step
                }
                // Bar lines, and beats once they are far enough apart to read.
                let visible = beatFrames.filter { $0 >= viewRange.lowerBound && $0 < viewRange.upperBound }
                let beatGap = visible.count > 1 ? size.width / CGFloat(visible.count) : size.width
                for b in visible {
                    let strong = downbeatFrames.contains(b)
                    if strong ? beatGap * 4 < 7 : beatGap < 14 { continue }
                    ctx.fill(Path(CGRect(x: toX(b), y: top, width: strong ? 1 : 0.75, height: body.height)),
                             with: .color(Theme.accent.opacity(strong ? 0.4 : 0.14)))
                }
                if !barLabels.isEmpty {
                    let shown = barLabels.filter { $0.frame >= viewRange.lowerBound && $0.frame < viewRange.upperBound }
                    // Bar spacing on screen decides how many numbers fit.
                    let gap = shown.count > 1 ? (toX(shown[shown.count - 1].frame) - toX(shown[0].frame)) / CGFloat(shown.count - 1) : size.width
                    let every = gap >= 22 ? 1 : gap >= 11 ? 2 : gap >= 5.5 ? 4 : gap >= 2.75 ? 8 : 0
                    if every > 0 {
                    for l in shown where every > 0 && (l.number - 1) % every == 0 {
                        ctx.draw(Text("\(l.number)").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent),
                                 at: CGPoint(x: toX(l.frame) + 3, y: top + 3), anchor: .topLeading)
                    }
                    }
                }
                // Waveform: grey outside the selection, accent inside.
                if let peaks {
                    let cols = Int(size.width)
                    let data = peaks.columns(cols, startFrame: viewRange.lowerBound, endFrame: viewRange.upperBound)
                    var path = Path()
                    let mid = body.midY, amp = body.height / 2 * 0.86
                    for (i, (lo, hi)) in data.enumerated() {
                        let y0 = mid - CGFloat(min(1, hi)) * amp, y1 = mid - CGFloat(max(-1, lo)) * amp
                        path.addRect(CGRect(x: CGFloat(i), y: y0, width: 0.8, height: max(1, y1 - y0)))
                    }
                    ctx.fill(path, with: .color(Theme.textSecondary.opacity(0.38)))
                    ctx.drawLayer { l in
                        l.clip(to: Path(selRect))
                        l.fill(path, with: .color(Theme.accent.opacity(0.62)))
                    }
                }
                // Selection edges: a line and a grip.
                for x in [sx, ex] where x >= -6 && x <= size.width + 6 {
                    ctx.fill(Path(CGRect(x: x - 1, y: top, width: 2, height: body.height)), with: .color(Theme.accent))
                    let grip = CGRect(x: x - 4.5, y: body.midY - 15, width: 9, height: 30)
                    ctx.fill(Path(roundedRect: grip, cornerRadius: 4.5), with: .color(Theme.accent))
                    for dy in [-5.0, 0, 5] {
                        ctx.fill(Path(CGRect(x: x - 2, y: body.midY + dy - 0.5, width: 4, height: 1)), with: .color(Theme.onAccent.opacity(0.9)))
                    }
                }
            }
            .overlay {
                // Playhead with a marker in the ruler, redrawn on its own.
                TimelineView(.animation(paused: !isPlaying)) { _ in
                    Canvas { ctx, size in
                        let top = rulerHeight
                        let px = toX(isPlaying ? AudioEngine.shared.positionFrames : playhead)
                        guard px >= 0, px <= size.width else { return }
                        ctx.fill(Path(CGRect(x: px - 0.75, y: top, width: 1.5, height: size.height - top)), with: .color(Theme.textPrimary))
                        var tri = Path()
                        tri.move(to: CGPoint(x: px - 5, y: top - 7)); tri.addLine(to: CGPoint(x: px + 5, y: top - 7)); tri.addLine(to: CGPoint(x: px, y: top))
                        ctx.fill(tri, with: .color(Theme.textPrimary))
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let sx = toX(selection.lowerBound), ex = toX(selection.upperBound)
                        if drag == nil {
                            let x = v.startLocation.x, inBody = v.startLocation.y > rulerHeight
                            if editable && inBody && abs(x - sx) <= 10 { drag = .left }
                            else if editable && inBody && abs(x - ex) <= 10 { drag = .right }
                            else if editable && inBody && x > sx && x < ex && abs(v.translation.width) > 2 { drag = .move }
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
                if case .active(let p) = phase, p.y > rulerHeight {
                    let sx = toX(selection.lowerBound), ex = toX(selection.upperBound)
                    if abs(p.x - sx) <= 10 || abs(p.x - ex) <= 10 { NSCursor.resizeLeftRight.set() }
                    else if p.x > sx && p.x < ex { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                } else { NSCursor.arrow.set() }
            }
            .frame(width: w, height: h)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func label(_ t: Double, step: Double) -> String {
        let m = Int(t) / 60, s = t - Double(m * 60)
        return step < 1 ? String(format: "%d:%04.1f", m, s) : String(format: "%d:%02d", m, Int(s.rounded()))
    }
}

/// The whole song in one strip: selection, playhead and the part shown above. Click or drag
/// to move the view there.
struct WaveformOverview: View {
    var peaks: WaveformPeaks?
    var totalFrames: Int64
    var selection: Range<Int64>
    var playhead: Int64
    @Binding var viewRange: Range<Int64>

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let toX = { (f: Int64) -> CGFloat in CGFloat(Double(f) / Double(max(1, totalFrames))) * w }
            Canvas { ctx, size in
                let selRect = CGRect(x: toX(selection.lowerBound), y: 0, width: max(2, toX(selection.upperBound) - toX(selection.lowerBound)), height: size.height)
                ctx.fill(Path(selRect), with: .color(Theme.accent.opacity(0.14)))
                if let peaks {
                    let data = peaks.columns(Int(size.width), startFrame: 0, endFrame: totalFrames)
                    var path = Path()
                    let mid = size.height / 2
                    for (i, (lo, hi)) in data.enumerated() {
                        let y0 = mid - CGFloat(min(1, hi)) * mid * 0.8, y1 = mid - CGFloat(max(-1, lo)) * mid * 0.8
                        path.addRect(CGRect(x: CGFloat(i), y: y0, width: 0.8, height: max(1, y1 - y0)))
                    }
                    ctx.fill(path, with: .color(Theme.textSecondary.opacity(0.35)))
                    ctx.drawLayer { l in l.clip(to: Path(selRect)); l.fill(path, with: .color(Theme.accent.opacity(0.7))) }
                }
                // The part shown above
                if viewRange.count < Int(totalFrames) {
                    let vx = toX(viewRange.lowerBound), vw = max(6, toX(viewRange.upperBound) - vx)
                    let vr = CGRect(x: vx, y: 1, width: vw, height: size.height - 2)
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: vx, height: size.height)), with: .color(Theme.background.opacity(0.55)))
                    ctx.fill(Path(CGRect(x: vr.maxX, y: 0, width: size.width - vr.maxX, height: size.height)), with: .color(Theme.background.opacity(0.55)))
                    ctx.stroke(Path(roundedRect: vr, cornerRadius: 4), with: .color(Theme.textPrimary.opacity(0.55)), lineWidth: 1.2)
                }
                ctx.fill(Path(CGRect(x: toX(playhead) - 0.5, y: 0, width: 1, height: size.height)), with: .color(Theme.textPrimary.opacity(0.8)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard viewRange.count < Int(totalFrames) else { return }
                let f = Int64(Double(max(0, min(w, v.location.x)) / max(1, w)) * Double(totalFrames))
                viewRange = TrackRange.centered(viewRange, total: totalFrames, on: f)
            })
            .onHover { inside in if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("整曲：点或拖动，上面的波形就移到那里")
    }
}

/// Fit buttons for a waveform's view, with the gesture hint. Zooming itself is on the trackpad.
struct ZoomBar: View {
    @Binding var viewRange: Range<Int64>
    var totalFrames: Int64
    var fitRange: Range<Int64>

    var body: some View {
        HStack(spacing: 4) {
            chip("整曲") { viewRange = 0..<max(1, totalFrames) }
            chip("看选区") {
                let pad = max(Int64(1), Int64(fitRange.count) / 8)
                viewRange = max(0, fitRange.lowerBound - pad)..<min(totalFrames, fitRange.upperBound + pad)
            }
            Text("双指上下滑缩放 · 左右滑平移").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).padding(.leading, 6)
        }
    }

    private func chip(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 9).frame(height: 22)
                .background(Capsule().fill(Theme.borderSubtle.opacity(0.7)))
                .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
    }
}
