import AVFoundation
import MusicnoteCore
import SwiftUI

/// "第 1 小节从哪里开始？" The transcription as a piano roll. The user puts bar 1 first; only
/// then are bar and beat lines drawn, counted from it at the confirmed tempo, so the grid (and
/// later the chords against the original) hangs off the note the user chose. Clicking or
/// dragging snaps to the nearest notes struck together (sounding them); with snapping off the
/// line goes exactly where it is put, with ±10 ms nudges. 播放核对 plays the stem with a click
/// on the implied beats under a smooth playhead. Two-finger swipes zoom and pan.
struct BarOneView: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var confirmTitle: String
    /// Right after transcription nothing is picked yet: no grid until the user puts bar 1.
    var requirePick = false
    var onConfirm: (Int64) -> Void
    var onKeep: () -> Void
    @AppStorage("barOneSnap") private var snapOn = true
    @ViewState private var picked: Int64?
    @ViewState private var hovered: Int64?
    @ViewState private var playing = false
    @ViewState private var view: Range<Int64> = 0..<1
    @ViewState private var stemRate: Double = 44100

    private var notes: [MidiNote] { model.workingMidi(item.id)?.notes ?? model.confirmedMidi(item)?.notes ?? [] }
    private var grid: BeatGrid? { item.timing?.grid }
    private var barUs: Double { (grid?.beatUs ?? 500_000) * (grid?.meter.quarterBeatsPerBar ?? 4) }
    private var total: Int64 { max(1, item.durationUs) }
    /// At first: at least 8 s and three bars from the start.
    private var initialView: Range<Int64> { 0..<min(total, Int64(max(8_000_000, barUs * 3.2))) }
    private var onsets: [BarOne.Onset] { BarOne.onsets(notes, untilUs: total) }
    private var current: Int64? {
        if let picked { return picked }
        return requirePick ? nil : item.timing?.barAnchorUs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("第 1 小节从哪里开始？").font(.system(size: 16, weight: .semibold))
                Text("先在卷帘上点出第 1 小节开始的那个音，再按 \(String(format: (grid?.bpm ?? 0).truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", grid?.bpm ?? 0)) BPM 从它往后分小节，之前的音算弱起。默认吸到音符开头；模型转错时可以关掉吸附自己拖。点「播放核对」带节拍器听重拍对不对。")
                    .font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            roll.frame(height: 280)
                .trackZoomPan(onZoom: { f, a in view = TrackRange.zoom(view, total: total, factor: f, anchor: a, minLength: 500_000) },
                              onPan: { d in view = TrackRange.pan(view, total: total, fraction: d) })
            HStack(spacing: 4) {
                Button { view = initialView } label: { chip("开头") }.buttonStyle(.plain)
                Button { view = 0..<total } label: { chip("整段") }.buttonStyle(.plain)
                Text("双指上下滑缩放 · 左右滑平移").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).padding(.leading, 6)
                Spacer()
                Toggle("吸附音符开头", isOn: $snapOn).toggleStyle(.switch).controlSize(.mini).font(.caption12)
                    .help("开：点到哪都吸到最近一组同时按下的音的开头。关：点哪是哪，可拖动、可 ±10 ms 微调")
            }
            HStack(spacing: 10) {
                if let c = current {
                    Text(String(format: "第 1 小节从 %.3f 秒开始", Double(c) / 1e6)).font(.mono13)
                    if let o = onsets.first(where: { abs($0.us - c) <= 1_000 }) {
                        Text(o.pitches.map { Pitch.noteName($0, flats: Pitch.prefersFlats(item.timing?.key)) }.joined(separator: " ")).font(.caption12).foregroundStyle(Theme.textSecondary)
                    }
                    if !snapOn {
                        HStack(spacing: 2) {
                            Button { nudge(-10_000) } label: { Image(systemName: "chevron.left") }
                            Text("10 ms").font(.caption12).foregroundStyle(Theme.textSecondary)
                            Button { nudge(10_000) } label: { Image(systemName: "chevron.right") }
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Label("先在卷帘上点第 1 小节开始的音", systemImage: "hand.point.up.left").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                }
                Spacer()
                Button { playing ? stop() : check() } label: { Label(playing ? "停止" : "播放核对", systemImage: playing ? "stop.fill" : "metronome") }
                    .buttonStyle(SecondaryButtonStyle(compact: true)).disabled(current == nil)
                if !requirePick { Button("保持现在的") { stop(); onKeep() }.buttonStyle(SecondaryButtonStyle(compact: true)) }
                Button(confirmTitle) { stop(); if let c = current { onConfirm(c) } }.buttonStyle(PrimaryButtonStyle()).disabled(current == nil)
            }
        }
        .onAppear { if view.count <= 1 { view = initialView } }
        .onDisappear { stop() }
        .task(id: playing) {
            // Follow the playhead and notice the end, without redrawing the roll every frame.
            while playing, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                if !AudioEngine.shared.isPlaying { playing = false; AudioEngine.shared.setMetronome(MetronomeConfig()); break }
                follow()
            }
        }
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(Theme.borderSubtle.opacity(0.7))).foregroundStyle(Theme.textPrimary)
    }

    private var roll: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let span = Double(max(1, view.count))
            let inView = notes.filter { $0.startUs < view.upperBound && $0.endUs > view.lowerBound }
            let shownPitches = (inView.isEmpty ? notes : inView).map(\.pitch)
            let lo = (shownPitches.min() ?? 48) - 2, hi = (shownPitches.max() ?? 72) + 2
            let x = { (us: Int64) -> CGFloat in w * CGFloat(Double(us - view.lowerBound) / span) }
            let y = { (p: Int) -> CGFloat in h * CGFloat(Double(hi - p) / Double(max(1, hi - lo))) }
            let rowH = max(3, min(10, h / CGFloat(max(1, hi - lo)) - 1))
            ZStack {
                Canvas { ctx, size in
                    if let c = current {
                        // Pickup before bar 1
                        if x(c) > 0 {
                            ctx.fill(Path(CGRect(x: 0, y: 0, width: min(size.width, x(c)), height: size.height)), with: .color(Theme.textSecondary.opacity(0.07)))
                        }
                        // Bar and beat lines, counted from bar 1
                        if let g = grid {
                            let per = Int(g.meter.quarterBeatsPerBar.rounded())
                            var k = Int(floor(Double(view.lowerBound - c) / g.beatUs))
                            let beatPx = Double(size.width) * g.beatUs / span
                            while true {
                                let t = c + Int64(Double(k) * g.beatUs)
                                if t > view.upperBound { break }
                                let bar = ((k % per) + per) % per == 0
                                if t >= 0, bar || beatPx >= 10 {
                                    ctx.fill(Path(CGRect(x: x(t), y: 0, width: bar ? 1.5 : 1, height: size.height)),
                                             with: .color(Theme.accent.opacity(bar ? 0.5 : 0.16)))
                                    if bar && k >= 0 && (beatPx * Double(per) >= 26 || (k / per) % 4 == 0) {
                                        ctx.draw(Text("\(k / per + 1)").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent),
                                                 at: CGPoint(x: x(t) + 3, y: 2), anchor: .topLeading)
                                    }
                                }
                                k += 1
                            }
                        }
                    }
                    // Notes; onsets marked so the heads are easy to aim at
                    for n in inView {
                        let r = CGRect(x: x(n.startUs), y: y(n.pitch) - rowH / 2, width: max(2, x(n.endUs) - x(n.startUs)), height: rowH)
                        let after = current.map { n.startUs >= $0 - 30_000 } ?? true
                        ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(after ? Theme.noteFill : Theme.noteFill.opacity(0.4)))
                        ctx.fill(Path(CGRect(x: r.minX, y: r.minY, width: min(2, r.width), height: r.height)), with: .color(Theme.chipText))
                    }
                    // Where a click would put bar 1, and bar 1 itself
                    if let hv = hovered, hv != current {
                        ctx.fill(Path(CGRect(x: x(hv) - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Theme.accent.opacity(0.4)))
                    }
                    if let c = current {
                        ctx.fill(Path(CGRect(x: x(c) - 1.5, y: 0, width: 3, height: size.height)), with: .color(Theme.accent))
                        var flag = Path()
                        flag.addRoundedRect(in: CGRect(x: x(c) - 1.5, y: size.height - 18, width: 18, height: 16), cornerSize: CGSize(width: 3, height: 3))
                        ctx.fill(flag, with: .color(Theme.accent))
                        ctx.draw(Text("1").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.onAccent), at: CGPoint(x: x(c) + 7.5, y: size.height - 10))
                    }
                }
                // The playhead redraws on its own at display rate, reading the engine directly.
                TimelineView(.animation(paused: !playing)) { _ in
                    Canvas { ctx, size in
                        guard playing else { return }
                        let ph = Int64(Double(AudioEngine.shared.positionFrames) / stemRate * 1e6)
                        let px = x(ph)
                        guard px >= 0, px <= size.width else { return }
                        ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Theme.textPrimary))
                        var tri = Path()
                        tri.move(to: CGPoint(x: px - 5, y: 0)); tri.addLine(to: CGPoint(x: px + 5, y: 0)); tri.addLine(to: CGPoint(x: px, y: 7))
                        ctx.fill(tri, with: .color(Theme.textPrimary))
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase { hovered = target(p.x, width: w).us; NSCursor.crosshair.set() } else { hovered = nil; NSCursor.arrow.set() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in picked = target(v.location.x, width: w).us; hovered = nil }
                .onEnded { v in
                    let t = target(v.location.x, width: w)
                    picked = t.us
                    if let o = t.onset { AudioEngine.shared.playChord(o.pitches, duration: 1.2) }
                    if playing { check() }
                })
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The time under the pointer: with snapping, the nearest onset (notes struck together);
    /// without, the exact time (to the millisecond).
    private func target(_ px: CGFloat, width: CGFloat) -> (us: Int64, onset: BarOne.Onset?) {
        let t = view.lowerBound + Int64(Double(px / max(1, width)) * Double(view.count))
        if snapOn, let o = BarOne.nearest(onsets, to: t) { return (o.us, o) }
        return (max(0, min(total, (t / 1000) * 1000)), nil)
    }

    private func nudge(_ d: Int64) {
        guard let c = current else { return }
        picked = max(0, min(total, c + d))
        if playing { check() }
    }

    /// Keeps the playhead in view while checking.
    private func follow() {
        let ph = Int64(Double(AudioEngine.shared.positionFrames) / stemRate * 1e6)
        if ph > view.upperBound - Int64(view.count) / 20 || ph < view.lowerBound {
            view = TrackRange.centered(view, total: total, on: ph + Int64(view.count) / 3)
        }
    }

    /// The stem from a beat before bar 1, with a click accented on the implied downbeats.
    private func check() {
        guard let c = current, let g = grid, let asset = item.transcriptionStem,
              let buf = try? AudioLoader.load(model.paths.url(relative: asset.relativePath)) else { return }
        let rate = buf.format.sampleRate
        func frame(_ us: Int64) -> Int64 { Int64(Double(us) / 1e6 * rate) }
        stemRate = rate
        let e = AudioEngine.shared
        e.pause()
        e.configure(sampleRate: rate)
        e.setMidi([], enabled: false)
        e.setTracks([AudioTrack(id: "stem", buffer: buf)])
        e.setLength(Int64(buf.frameLength))
        e.setLoop(nil)
        var m = MetronomeConfig()
        m.enabled = true
        m.bpm = g.bpm
        m.originFrame = frame(c)
        m.barAnchorFrame = frame(c)
        m.beatsPerBar = g.meter.quarterBeatsPerBar
        e.setMetronome(m)
        e.play(from: frame(max(0, c - Int64(g.beatUs))))
        playing = true
    }

    private func stop() {
        guard playing else { return }
        AudioEngine.shared.pause()
        AudioEngine.shared.setMetronome(MetronomeConfig())
        playing = false
    }
}

/// After transcription: confirm bar 1, then harmony runs.
struct BarOneStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var transport: TransportModel
    @ViewState private var editingMidi = false

    var body: some View {
        if editingMidi {
            MidiStage(item: item, transport: transport)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                BarOneView(item: item, confirmTitle: "就从这里开始，分析和声", requirePick: true,
                           onConfirm: { us in model.confirmBarOne(item.id, atUs: us) },
                           onKeep: { model.confirmBarOne(item.id, atUs: nil) })
                HStack(spacing: 16) {
                    Button("先打开 MIDI 看看") { editingMidi = true }.buttonStyle(.borderless).font(.caption12)
                    ReselectStemsButton(item: item)
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
        }
    }
}

/// 重选分轨: when the chosen stem turns out poor, go back to choosing stems (separating the
/// trimmed clip again if the other stems were removed) and transcribe again.
struct ReselectStemsButton: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var compact = true
    @ViewState private var asking = false

    var body: some View {
        Group {
            if compact {
                Button { asking = true } label: { Label("效果不好？重选分轨", systemImage: "arrow.triangle.branch") }
                    .buttonStyle(.borderless).font(.caption12)
            } else {
                Button { asking = true } label: { Label("重选分轨…", systemImage: "arrow.triangle.branch") }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
        }
        .help("回到选分轨：换一个或多选几个分轨重新转 MIDI。截好的选区还在。")
        .confirmationDialog("重选分轨？", isPresented: $asking) {
            Button(model.reselectNeedsSeparation(item) ? "重新拆轨并选分轨" : "回到选分轨") { model.reselectStems(item.id) }
        } message: {
            Text((model.reselectNeedsSeparation(item) ? "其他分轨在上次确认后已删掉，会先用截好的选区重新拆一次轨（要几分钟）。" : "会回到试听并选择分轨。")
                 + "重新转 MIDI 后要再确认一次第 1 小节，然后重新分析和声。笔记、标签和旧版本都保留"
                 + (model.harmonyDraft(item.id) != nil ? "；正在核对、还没确定的和声修改会丢掉" : "") + "。")
        }
    }
}
