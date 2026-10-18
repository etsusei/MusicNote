import MusicnoteCore
import SwiftUI

/// 灵感集合: every saved 灵感进行 with its bars; each plays or loops at its own speed and key
/// (smart transposition keeps the sound in range and respells the names).
struct InspirationCollectionPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var transport = TransportModel()
    @ViewState private var looping: Set<UUID> = []
    @ViewState private var deleting: InspirationProgression?

    var body: some View {
        let _ = model.dataVersion
        let list = model.inspirationList
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionHeader(title: "灵感集合", subtitle: "在“灵感进行”窗口里拼好、保存的进行。每条可以单独调速度和调号。")
                    Spacer()
                    Button { InspirationWindow.shared.show(model) } label: { Label("打开灵感进行", systemImage: "lightbulb.max") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if list.isEmpty {
                    Card { Text("还没有保存的灵感进行。点右下角的灯泡打开窗口，从分析里把喜欢的和弦拖进去。").foregroundStyle(Theme.textSecondary) }
                }
                ForEach(list) { p in card(p) }
            }
            .padding(24)
        }
        .onAppear { transport.sampleRate = AppModel.inspirationRate }
        .onDisappear { if model.playingInspiration != nil { model.stopInspiration() }; transport.stop() }
        .confirmationDialog("删除这条灵感进行？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let d = deleting { model.deleteInspiration(d.id) } }
            Button("取消", role: .cancel) {}
        } message: { Text(deleting?.displayTitle ?? "") }
    }

    private func card(_ p: InspirationProgression) -> some View {
        let playing = model.playingInspiration == p.id && transport.isPlaying
        let q = Double(transport.positionFrame) / AppModel.inspirationRate * max(20, p.bpm) / 60
        let detected = InspirationTranspose.detectedKey(p)
        let n = InspirationTranspose.semitones(p)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField(p.displayTitle, text: Binding(get: { p.title }, set: { t in model.updateCollectionEntry(p.id) { $0.title = t } }))
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold)).frame(maxWidth: 320)
                Spacer()
                Button { playing ? model.stopInspiration() : model.playInspiration(p, loop: looping.contains(p.id), transpose: true) } label: {
                    Label(playing ? "停止" : "播放", systemImage: playing ? "stop.fill" : "play.fill")
                }.buttonStyle(SecondaryButtonStyle(compact: true)).disabled(p.chords.isEmpty)
                Toggle(isOn: Binding(get: { looping.contains(p.id) }, set: { on in
                    if on { looping.insert(p.id) } else { looping.remove(p.id) }
                    if playing { model.playInspiration(p, loop: on, transpose: true) }
                })) { Label("循环", systemImage: "repeat") }.toggleStyle(.button)
                Menu {
                    Button("在灵感进行里编辑") { model.editInspiration(p.id) }
                    Button("删除…", role: .destructive) { deleting = p }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
            }
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("速度").font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize()
                    Slider(value: Binding(get: { p.bpm }, set: { v in model.updateCollectionEntry(p.id) { $0.bpm = v.rounded() } }), in: 40...200)
                        .frame(width: 140)
                        .onSubmit {}
                    Text("\(Int(p.bpm)) BPM").font(.mono13).frame(width: 64, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Text("调号").font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize()
                    Picker("", selection: Binding(get: { p.targetKey }, set: { k in model.updateCollectionEntry(p.id) { $0.targetKey = k } })) {
                        Text("原调" + (detected.map { "（\($0.display)）" } ?? "")).tag(KeySignature?.none)
                        Divider()
                        ForEach(Self.keys, id: \.self) { k in Text(k.display).tag(KeySignature?.some(k)) }
                    }.labelsHidden().frame(width: 150)
                    if let d = detected, let t = p.targetKey, n != 0 {
                        Text("\(d.display) → \(t.display)，\(n > 0 ? "升" : "降") \(abs(n)) 半音").font(.caption12).foregroundStyle(Theme.textSecondary)
                    }
                }
                Toggle("智能移调", isOn: Binding(get: { p.smartTranspose }, set: { v in model.updateCollectionEntry(p.id) { $0.smartTranspose = v } }))
                    .toggleStyle(.checkbox).font(.caption12)
                    .help("走最近的方向变调，并把每个和弦整体挪到舒服的音区（最低音约 C2–C3、最高不超过 C6），和弦名按新调拼写")
                Spacer()
            }
            InspirationBarsView(progression: p, editable: false, playingQ: playing ? q : nil,
                                // Degrees in the key shown (picked, else detected); the name stays in the tooltip.
                                displayName: { c in
                                    let sym = InspirationTranspose.symbol(c, by: n, key: p.targetKey)
                                    return (p.targetKey ?? detected).flatMap { Degrees.label(symbol: sym, key: $0)?.display } ?? sym
                                },
                                tooltip: { c in InspirationTranspose.symbol(c, by: n, key: p.targetKey) },
                                soundPitches: { c in InspirationTranspose.pitches(c, by: n, smart: p.targetKey != nil && p.smartTranspose) },
                                compact: true)
            if !p.sourceLabels.isEmpty {
                Text("来自：" + p.sourceLabels.joined(separator: "、")).font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(playing ? Theme.accent.opacity(0.6) : Theme.borderSubtle))
    }

    /// The 24 keys, spelled the usual way.
    static let keys: [KeySignature] = {
        let major = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        let minor = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"]
        return (0..<12).map { KeySignature(tonic: $0, tonicName: major[$0], mode: .major) }
            + (0..<12).map { KeySignature(tonic: $0, tonicName: minor[$0], mode: .minor) }
    }()
}
