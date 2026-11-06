import MusicnoteCore
import SwiftUI

/// Right panel of the drum machine: the selected lane and step, bar tools, adding lanes and
/// where the pattern came from.
struct DrumInspector: View {
    @Environment(AppModel.self) private var model
    @Binding var pattern: DrumPattern
    @Binding var selectedLane: UUID?
    @Binding var selectedStep: Int?
    @Binding var bars: ClosedRange<Int>?
    var begin: () -> Void
    var apply: ((inout DrumGroove) -> Void) -> Void
    var editPattern: ((inout DrumPattern) -> Void) -> Void

    private var g: DrumGroove { pattern.groove }
    private var laneIndex: Int? { g.lanes.firstIndex { $0.id == selectedLane } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let li = laneIndex { laneSection(li) }
                if let li = laneIndex, let si = selectedStep, let s = g.lanes[li].step(at: si) { stepSection(li, s) }
                barSection
                addLane
                if let src = pattern.source { sourceSection(src) }
            }
            .padding(14)
        }
        .background(Theme.surface)
    }

    private func edit(_ f: (inout DrumGroove) -> Void) { begin(); apply(f) }

    private func title(_ t: String) -> some View { Text(t).font(.system(size: 13, weight: .semibold)) }

    // MARK: Lane

    private func laneSection(_ li: Int) -> some View {
        let lane = g.lanes[li]
        return VStack(alignment: .leading, spacing: 8) {
            title("轨道")
            TextField("轨道名", text: Binding(get: { lane.name }, set: { n in pattern.groove.lanes[li].name = n })).textFieldStyle(.roundedBorder)
            Picker("声音", selection: Binding(get: { lane.note }, set: { n in edit { $0.lanes[li].note = n }; AudioEngine.shared.tapDrum(n, velocity: 110) })) {
                ForEach(GMDrum.sounds, id: \.note) { Text("\($0.name)（\($0.note)）").tag($0.note) }
                if !GMDrum.sounds.contains(where: { $0.note == lane.note }) { Text("音符 \(lane.note)").tag(lane.note) }
            }
            if let piece = lane.piece { Text("对应原曲的\(piece.displayName)轨（对照选「本轨原声」）").font(.caption12).foregroundStyle(Theme.textSecondary) }
            HStack {
                Text("音量").font(.caption12)
                Slider(value: Binding(get: { lane.volume }, set: { pattern.groove.lanes[li].volume = $0 }), in: 0...1) { if $0 { begin() } }
                Text("\(Int((lane.volume * 100).rounded()))%").font(.mono13).frame(width: 40, alignment: .trailing)
            }
            Text("快速填充（替换本轨）").font(.caption12).foregroundStyle(Theme.textSecondary)
            FlowLayout(spacing: 4) {
                fill("每拍", every: g.stepsPerBeat)
                if g.stepsPerBeat % 2 == 0 {
                    fill("八分", every: g.stepsPerBeat / 2)
                    fill("反拍八分", every: g.stepsPerBeat, offset: g.stepsPerBeat / 2)
                }
                fill(g.stepsPerBeat == 3 ? "三连音" : "每格", every: 1)
                fill("2、4 拍", every: 2 * g.stepsPerBeat, offset: g.stepsPerBeat)
            }
            HStack(spacing: 6) {
                Button { edit { DrumOps.shift(&$0, lane: lane.id, by: -1) } } label: { Image(systemName: "arrow.left") }.help("整轨前移一格（循环）")
                Button { edit { DrumOps.shift(&$0, lane: lane.id, by: 1) } } label: { Image(systemName: "arrow.right") }.help("整轨后移一格（循环）")
                Button("清空本轨") { edit { $0.lanes[li].steps = [] }; selectedStep = nil }
                Spacer()
                Button(role: .destructive) {
                    edit { $0.lanes.remove(at: li) }
                    selectedLane = g.lanes.first?.id; selectedStep = nil
                } label: { Image(systemName: "trash") }.help("删除轨道").disabled(g.lanes.count <= 1)
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            HStack(spacing: 6) {
                Button { move(li, -1) } label: { Image(systemName: "arrow.up") }.disabled(li == 0).help("上移轨道")
                Button { move(li, 1) } label: { Image(systemName: "arrow.down") }.disabled(li == g.lanes.count - 1).help("下移轨道")
            }
            .buttonStyle(.borderless)
            Divider()
        }
    }

    private func fill(_ name: String, every: Int, offset: Int = 0) -> some View {
        Button(name) {
            guard let li = laneIndex else { return }
            let id = g.lanes[li].id
            edit { DrumOps.fill(&$0, lane: id, every: every, offset: offset) }
        }
        .buttonStyle(SecondaryButtonStyle(compact: true))
    }

    private func move(_ li: Int, _ d: Int) {
        let j = li + d
        guard j >= 0, j < g.lanes.count else { return }
        edit { $0.lanes.swapAt(li, j) }
    }

    // MARK: Step

    private func stepSection(_ li: Int, _ s: DrumStep) -> some View {
        let lane = g.lanes[li]
        let bar = s.index / g.stepsPerBar + 1
        let inBar = s.index % g.stepsPerBar
        let beat = inBar / g.stepsPerBeat + 1, sub = inBar % g.stepsPerBeat + 1
        let stepMs = 60_000 / pattern.bpm / Double(g.stepsPerBeat)
        func set(_ f: @escaping (inout DrumStep) -> Void) {
            apply { gr in
                guard var st = gr.lanes[li].step(at: s.index) else { return }
                f(&st); DrumOps.setStep(&gr, lane: lane.id, st)
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            title("所选的一步")
            Text("\(lane.name) · 第 \(bar) 小节第 \(beat) 拍" + (g.stepsPerBeat > 1 ? " 第 \(sub) 格" : "")).font(.caption12).foregroundStyle(Theme.textSecondary)
            row("力度", "\(s.velocity)") { Slider(value: Binding(get: { Double(s.velocity) }, set: { v in set { $0.velocity = Int(v) } }), in: 1...127) { if $0 { begin() } } }
            row("微移", String(format: "%+.0f%% · %+.0f ms", s.nudge * 100, s.nudge * stepMs)) {
                Slider(value: Binding(get: { s.nudge }, set: { v in set { $0.nudge = (v * 100).rounded() / 100 } }), in: -0.5...0.5) { if $0 { begin() } }
            }
            row("概率", "\(s.chance)%") { Slider(value: Binding(get: { Double(s.chance) }, set: { v in set { $0.chance = Int(v) } }), in: 0...100, step: 5) { if $0 { begin() } } }
            HStack {
                Text("连击").font(.caption12).frame(width: 34, alignment: .leading)
                Picker("", selection: Binding(get: { s.repeats }, set: { n in begin(); set { $0.repeats = n } })) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            HStack {
                Button("清除微移") { begin(); set { $0.nudge = 0 } }.disabled(s.nudge == 0)
                Spacer()
                Button("删除这一步", role: .destructive) { edit { DrumOps.removeStep(&$0, lane: lane.id, index: s.index) }; selectedStep = nil }
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            Divider()
        }
    }

    private func row<C: View>(_ name: String, _ value: String, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(name).font(.caption12); Spacer(); Text(value).font(.mono13).foregroundStyle(Theme.textSecondary) }
            control()
        }
    }

    // MARK: Bars

    private var barSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("小节")
            if let b = bars, b.upperBound < g.bars {
                Text(b.count == 1 ? "已选第 \(b.lowerBound + 1) 小节" : "已选第 \(b.lowerBound + 1)–\(b.upperBound + 1) 小节").font(.caption12).foregroundStyle(Theme.textSecondary)
                FlowLayout(spacing: 4) {
                    Button("复制到后面") { copyForward(b) }.disabled(b.upperBound + b.count + 1 > 64)
                        .help("把所选小节复制到紧接着的小节（不够就加小节）")
                    Button("清空") { edit { gr in for bar in b { DrumOps.clearBar(&gr, bar) } } }
                    Button("只保留这些") { crop(b.lowerBound..<(b.upperBound + 1)) }
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            } else {
                Text("点小节号选中小节，⇧ 点选连续几小节；选中后循环播放这几小节。").font(.caption12).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 4) {
                Button("整段复制一遍") { edit { DrumOps.duplicate(&$0) } }.disabled(g.bars * 2 > 64)
                Menu("找代表性循环") {
                    ForEach([1, 2, 4, 8], id: \.self) { n in
                        Button("\(n) 小节") { if let s = DrumOps.representativeLoop(g, bars: n) { bars = s...(s + n - 1) } }.disabled(g.bars < n)
                    }
                }
                .fixedSize()
                .help("在整段里找最典型的一段（与其他段最像），选中后可以「只保留这些」")
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            Divider()
        }
    }

    private func copyForward(_ b: ClosedRange<Int>) {
        edit { gr in
            let need = b.upperBound + b.count + 1
            if need > gr.bars { DrumOps.setBars(&gr, min(64, need)) }
            for (k, bar) in b.enumerated() where b.upperBound + 1 + k < gr.bars { DrumOps.copyBar(&gr, from: bar, to: b.upperBound + 1 + k) }
        }
    }

    private func crop(_ r: Range<Int>) {
        editPattern { p in
            DrumOps.crop(&p.groove, bars: r)
            p.source?.cropBars += r.lowerBound
        }
        bars = nil; selectedStep = nil
    }

    // MARK: Lanes and source

    private var addLane: some View {
        Menu("添加轨道") {
            ForEach(GMDrum.sounds, id: \.note) { s in
                Button("\(s.name)（\(s.note)）") {
                    let lane = DrumLane(name: s.name, note: s.note)
                    edit { $0.lanes.append(lane) }
                    selectedLane = lane.id
                    AudioEngine.shared.tapDrum(s.note, velocity: 110)
                }
            }
        }
        .fixedSize()
    }

    private func sourceSection(_ src: DrumSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            title("提取说明")
            ForEach(src.notes ?? [], id: \.self) { Text($0).font(.caption12).foregroundStyle(Theme.textSecondary) }
            Text("Logic Pro \(src.logicVersion ?? "?") 鼓细分；每一步的微移是离格子的实际偏差。漏掉或多出的音直接在格子上改。")
                .font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if src.cropBars > 0 { Text("已从前面裁掉 \(src.cropBars) 小节（原声对照仍对齐）").font(.caption12).foregroundStyle(Theme.textSecondary) }
        }
    }
}
