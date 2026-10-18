import AVFoundation
import MusicnoteCore
import SwiftUI

/// "第 1 小节从哪个音开始？" The opening of the transcription as a piano roll; notes struck
/// together form one onset. Picking one shows the bar and beat lines it implies (at the confirmed
/// tempo) and sounds it; 播放核对 plays the stem with a click accented on the downbeats.
struct BarOneView: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var confirmTitle: String
    var onConfirm: (Int64) -> Void
    var onKeep: () -> Void
    @ViewState private var picked: Int64?
    @ViewState private var hovered: Int64?
    @ViewState private var playing = false

    private var notes: [MidiNote] { model.workingMidi(item.id)?.notes ?? model.confirmedMidi(item)?.notes ?? [] }
    private var grid: BeatGrid? { item.timing?.grid }
    private var barUs: Double { (grid?.beatUs ?? 500_000) * (grid?.meter.quarterBeatsPerBar ?? 4) }
    /// At least 8 s and three bars, within the clip.
    private var windowUs: Int64 { min(item.durationUs, Int64(max(8_000_000, barUs * 3.2))) }
    private var onsets: [BarOne.Onset] { BarOne.onsets(notes, untilUs: windowUs) }
    private var current: Int64 { picked ?? BarOne.nearest(onsets, to: item.timing?.barAnchorUs ?? 0)?.us ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("第 1 小节从哪个音开始？").font(.system(size: 16, weight: .semibold))
                Text("点卷帘里的那个音（同时按下的算一个）。会按 \(String(format: (grid?.bpm ?? 0).truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", grid?.bpm ?? 0)) BPM 画出小节线和拍线；它之前的音算弱起。点“播放核对”带节拍器听重拍对不对。")
                    .font(.caption12).foregroundStyle(Theme.textSecondary)
            }
            roll.frame(height: 260)
            HStack(spacing: 10) {
                Text(String(format: "第 1 小节从 %.3f 秒开始", Double(current) / 1e6)).font(.mono13)
                if let o = onsets.first(where: { $0.us == current }) {
                    Text(o.pitches.map { Pitch.noteName($0, flats: Pitch.prefersFlats(item.timing?.key)) }.joined(separator: " ")).font(.caption12).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { playing ? stop() : check() } label: { Label(playing ? "停止" : "播放核对", systemImage: playing ? "stop.fill" : "metronome") }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("保持现在的") { stop(); onKeep() }.buttonStyle(SecondaryButtonStyle(compact: true))
                Button(confirmTitle) { stop(); onConfirm(current) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .onDisappear { stop() }
    }

    private var roll: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let win = Double(windowUs)
            let inWin = notes.filter { $0.startUs < windowUs }
            let lo = (inWin.map(\.pitch).min() ?? 48) - 2, hi = (inWin.map(\.pitch).max() ?? 72) + 2
            let x = { (us: Int64) -> CGFloat in w * CGFloat(Double(us) / win) }
            let y = { (p: Int) -> CGFloat in h * CGFloat(Double(hi - p) / Double(max(1, hi - lo))) }
            let rowH = max(3, h / CGFloat(max(1, hi - lo)) - 1)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Pickup before bar 1
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: x(current), height: size.height)), with: .color(Theme.textSecondary.opacity(0.08)))
                    // Beat and bar lines implied by the pick
                    if let g = grid {
                        let per = Int(g.meter.quarterBeatsPerBar.rounded())
                        var k = -Int((Double(current) / g.beatUs).rounded(.up)) - 1
                        while true {
                            let t = current + Int64(Double(k) * g.beatUs)
                            if t > windowUs { break }
                            if t >= 0 {
                                let bar = ((k % per) + per) % per == 0
                                ctx.fill(Path(CGRect(x: x(t), y: 0, width: bar ? 1.5 : 1, height: size.height)),
                                         with: .color(Theme.accent.opacity(bar ? 0.55 : 0.18)))
                                if bar && k >= 0 {
                                    ctx.draw(Text("\(k / per + 1)").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent),
                                             at: CGPoint(x: x(t) + 3, y: 2), anchor: .topLeading)
                                }
                            }
                            k += 1
                        }
                    }
                    // Notes
                    for n in inWin {
                        let r = CGRect(x: x(n.startUs), y: y(n.pitch) - rowH / 2, width: max(2, x(min(n.endUs, windowUs)) - x(n.startUs)), height: rowH)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(n.startUs >= current - 30_000 ? Theme.noteFill : Theme.noteFill.opacity(0.45)))
                    }
                    // Hovered and picked onsets
                    if let hv = hovered, hv != current {
                        ctx.fill(Path(CGRect(x: x(hv) - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.textPrimary.opacity(0.35)))
                    }
                    ctx.fill(Path(CGRect(x: x(current) - 1.5, y: 0, width: 3, height: size.height)), with: .color(Theme.accent))
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let p) = phase { hovered = nearestOnset(p.x, width: w)?.us } else { hovered = nil }
                }
                .onTapGesture(coordinateSpace: .local) { p in
                    guard let o = nearestOnset(p.x, width: w) else { return }
                    picked = o.us
                    AudioEngine.shared.playChord(o.pitches, duration: 1.2)
                    if playing { check() }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.borderSubtle))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func nearestOnset(_ px: CGFloat, width: CGFloat) -> BarOne.Onset? {
        let t = Int64(Double(px / max(1, width)) * Double(windowUs))
        guard let o = BarOne.nearest(onsets, to: t) else { return nil }
        return abs(Double(o.us - t)) / Double(windowUs) * Double(width) <= 14 ? o : nil
    }

    /// The stem from just before the pick, with a click accented on the implied downbeats.
    private func check() {
        guard let g = grid, let asset = item.transcriptionStem,
              let buf = try? AudioLoader.load(model.paths.url(relative: asset.relativePath)) else { return }
        let rate = buf.format.sampleRate
        func frame(_ us: Int64) -> Int64 { Int64(Double(us) / 1e6 * rate) }
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
        m.originFrame = frame(current)
        m.barAnchorFrame = frame(current)
        m.beatsPerBar = g.meter.quarterBeatsPerBar
        e.setMetronome(m)
        e.play(from: frame(max(0, current - Int64(g.beatUs))))
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
                BarOneView(item: item, confirmTitle: "就从这里开始，分析和声",
                           onConfirm: { us in model.confirmBarOne(item.id, atUs: us) },
                           onKeep: { model.confirmBarOne(item.id, atUs: nil) })
                Button("先打开 MIDI 看看") { editingMidi = true }.buttonStyle(.borderless).font(.caption12)
                Spacer()
            }
            .padding(24)
        }
    }
}
