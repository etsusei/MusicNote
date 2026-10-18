import MusicnoteCore
import SwiftUI
import UniformTypeIdentifiers

struct PlaygroundSendRequest: Identifiable {
    enum Kind: Equatable { case chord(String), progression, skeleton }
    let id = UUID()
    var itemId: UUID
    var kind: Kind
}

/// Sends library material into a Playground project as snapshot blocks.
struct PlaygroundSendSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var request: PlaygroundSendRequest
    @ViewState private var projectId: UUID?
    @ViewState private var sectionIndex = 0
    @ViewState private var voicing: VoicingMode = .original
    @ViewState private var octave = 0
    @ViewState private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("送入 Playground").font(.sectionTitle)
            Text(kindText).font(.caption12).foregroundStyle(Theme.textSecondary)
            Picker("作品", selection: $projectId) {
                Text("新建作品").tag(UUID?.none)
                ForEach(model.playgrounds) { Text($0.title).tag(Optional($0.id)) }
            }
            if let p = project {
                Picker("乐段", selection: $sectionIndex) {
                    ForEach(Array(p.sections.enumerated()), id: \.offset) { i, s in Text("\(s.name)（\(s.barCount) 小节）").tag(i) }
                }
            }
            Picker("按法", selection: $voicing) { Text("原曲按法").tag(VoicingMode.original); Text("标准按法").tag(VoicingMode.standard) }
                .pickerStyle(.segmented)
            Stepper("整体八度 \(octave >= 0 ? "+" : "")\(octave)", value: $octave, in: -3...3)
            if let message { Text(message).font(.caption12).foregroundStyle(Theme.warning) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("送入") { insert() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { projectId = model.playgrounds.first?.id }
    }

    private var project: PlaygroundProject? { projectId.flatMap { id in model.playgrounds.first { $0.id == id } } }

    private var kindText: String {
        switch request.kind {
        case .chord: "单个原曲和弦：保留名称、实际 voicing 与原时间跨度。"
        case .progression: "完整原曲进行：所有事件（含经过和弦）、实际排列与时值；延音只触发一次。"
        case .skeleton: "简化骨架：主干块延长到下一个主干起点，标为简化节奏，保留回到完整进行的来源。"
        }
    }

    private func insert() {
        guard let item = model.item(request.itemId), let timing = item.timing, let h = model.latestHarmony(item.id),
              let midi = model.confirmedMidi(item) else { message = "这个片段还没有确认的 MIDI 与和声"; return }
        var p = project ?? {
            let np = PlaygroundProject(title: "\(model.song(item.songId)?.title ?? "新作品") 练习", key: timing.key, bpm: timing.bpm, meter: timing.meter)
            return np
        }()
        let ctx = PlaygroundOps.SourceContext(analysisId: item.id, harmonyRevision: h.revision, timing: timing, notes: midi.notes,
                                              segmentDurationUs: item.durationUs)
        do {
            var blocks: [ChordBlock]
            switch request.kind {
            case .chord(let id):
                blocks = try PlaygroundOps.blocks(events: h.events.filter { $0.id == id }, context: ctx, kind: "chord", voicing: voicing, target: p.key, octaveShift: octave)
            case .progression:
                blocks = try PlaygroundOps.blocks(events: h.events, context: ctx, kind: "progression", voicing: voicing, target: p.key, octaveShift: octave)
            case .skeleton:
                guard let sk = model.latestSkeleton(item.id), !sk.backboneEventIds.isEmpty else { message = "还没有骨架"; return }
                blocks = try PlaygroundOps.skeletonBlocks(backbone: sk.backboneEventIds, events: h.events, context: ctx, voicing: voicing, target: p.key, octaveShift: octave)
            }
            guard !blocks.isEmpty else { message = "没有可送入的和弦"; return }
            let si = min(sectionIndex, p.sections.count - 1)
            let total = (blocks.map(\.endQ).max() ?? 0)
            let sectionLen = PlaygroundOps.sectionLengthQ(p, p.sections[si])
            let start = p.sections[si].blocks.map(\.endQ).max() ?? 0
            if start + total > sectionLen {
                // Extend the section instead of dropping material.
                let needed = Int(ceil((start + total) / p.meter.quarterBeatsPerBar))
                p.sections[si].barCount = max(p.sections[si].barCount, needed)
            }
            for var b in blocks { b.startQ += start; p.sections[si].blocks.append(b) }
            model.save(p)
            model.reload()
            dismiss()
            model.route = .playground(p.id)
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Playground page

struct PlaygroundPage: View {
    @Environment(AppModel.self) private var model
    @ViewState var project: PlaygroundProject
    @ViewState private var selectedBlock: UUID?
    @ViewState private var selectedSection = 0
    @ViewState private var transport = TransportModel()
    @ViewState private var loop = false
    @ViewState private var range = 0 // 0 全曲, 1 当前乐段, 2 选中块
    @ViewState private var problems: [PlaygroundOps.Problem] = []
    @ViewState private var showExportReport = false
    @ViewState private var pxPerBeat: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionStrip
                        ForEach(Array(project.sections.enumerated()), id: \.element.id) { i, s in
                            SectionLane(project: $project, index: i, selectedBlock: $selectedBlock, selectedSection: $selectedSection,
                                        pxPerBeat: pxPerBeat, playheadQ: playheadQ(for: i))
                        }
                    }
                    .padding(20)
                }
                .frame(minWidth: 420)
                MaterialPanel(project: $project, selectedSection: $selectedSection, selectedBlock: $selectedBlock)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
            }
            Divider()
            transportBar
        }
        .onChange(of: project) { _, p in model.save(p) }
        .onAppear { AudioEngine.shared.stopAll(); transport.sampleRate = 44100 }
        .onDisappear { AudioEngine.shared.stopAll(); transport.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in togglePlay() }
        .alert("导出前检查", isPresented: $showExportReport) {
            Button("仍然导出") { writeMidi() }
            Button("取消", role: .cancel) {}
        } message: { Text(problems.map(\.message).joined(separator: "\n")) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            TextField("作品名", text: $project.title).font(.pageTitle).textFieldStyle(.plain).frame(maxWidth: 280)
            Picker("调", selection: Binding(get: { project.key.tonic }, set: { pc in
                project.key = KeySignature(tonic: pc, tonicName: Pitch.name(pc: pc, flats: Pitch.prefersFlats(project.key)), mode: project.key.mode)
            })) { ForEach(0..<12, id: \.self) { Text(Pitch.name(pc: $0, flats: [1, 3, 5, 8, 10].contains($0))).tag($0) } }.frame(width: 110)
            Picker("", selection: $project.key.mode) { Text("大调").tag(Mode.major); Text("小调").tag(Mode.minor) }.pickerStyle(.segmented).frame(width: 110)
            HStack(spacing: 4) {
                Text("BPM")
                TextField("", value: $project.bpm, format: .number.precision(.fractionLength(1))).frame(width: 60).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 2) {
                Stepper("\(project.meter.numerator)", value: $project.meter.numerator, in: 1...15).frame(width: 60)
                Text("/")
                Picker("", selection: $project.meter.denominator) { ForEach([2, 4, 8], id: \.self) { Text("\($0)").tag($0) } }.frame(width: 56)
            }
            Spacer()
            Text("改作品 BPM 会改变播放秒数（创作行为），与分析页修改 BPM 不同。").font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(2).frame(maxWidth: 220)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var sectionStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(project.sections.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 4) {
                    Text(s.name).font(.system(size: 12, weight: i == selectedSection ? .semibold : .regular))
                    Text("\(s.barCount)").font(.caption12).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(i == selectedSection ? Theme.selectionFill : Theme.surface))
                .overlay(Capsule().stroke(Theme.borderSubtle))
                .onTapGesture { selectedSection = i }
            }
            Menu("添加乐段") {
                ForEach(["Intro", "Verse", "Pre-Chorus", "Chorus", "Bridge", "A", "B", "Outro"], id: \.self) { n in
                    Button(n) { project.sections.append(PlaygroundSection(name: n, barCount: 8)); selectedSection = project.sections.count - 1 }
                }
                Button("自定义…") { project.sections.append(PlaygroundSection(name: "段落 \(project.sections.count + 1)", barCount: 4)) }
            }.frame(width: 100)
            Spacer()
            Slider(value: $pxPerBeat, in: 12...60).frame(width: 100).help("缩放")
        }
    }

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button { togglePlay() } label: { Label(transport.isPlaying ? "停止" : "播放", systemImage: transport.isPlaying ? "stop.fill" : "play.fill") }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            Picker("", selection: $range) { Text("全曲").tag(0); Text("当前乐段").tag(1); Text("选中块").tag(2) }
                .pickerStyle(.segmented).frame(width: 220)
            Toggle("循环", isOn: $loop).toggleStyle(.checkbox)
            InstrumentPicker()
            Spacer()
            Text("MIDI 只保存演奏事件；音色由 Logic 里的乐器决定。").font(.caption12).foregroundStyle(Theme.textSecondary)
            Button("导出 MIDI…") { problems = PlaygroundOps.problems(project); if problems.isEmpty { writeMidi() } else { showExportReport = true } }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    // MARK: Playback

    private var playRange: (sections: Range<Int>, startQ: Double, endQ: Double)? {
        switch range {
        case 1:
            let i = min(selectedSection, project.sections.count - 1)
            guard i >= 0 else { return nil }
            return (i..<(i + 1), 0, PlaygroundOps.sectionLengthQ(project, project.sections[i]))
        case 2:
            for (i, s) in project.sections.enumerated() {
                if let b = s.blocks.first(where: { $0.id == selectedBlock }) { return (i..<(i + 1), b.startQ, b.endQ) }
            }
            return nil
        default:
            let total = project.sections.reduce(0.0) { $0 + PlaygroundOps.sectionLengthQ(project, $1) }
            return (0..<project.sections.count, 0, total)
        }
    }

    private func frames(_ q: Double) -> Int64 { Int64(q * 60 / project.bpm * 44100) }

    private func togglePlay() {
        let e = AudioEngine.shared
        if e.isPlaying { e.pause(); return }
        guard let r = playRange else { return }
        let notes = PlaygroundOps.flatten(project, sections: r.sections)
            .filter { $0.startQ < r.endQ && $0.startQ + $0.durationQ > r.startQ }
            .map { ScheduledNote(startFrame: frames(max(0, $0.startQ - r.startQ)), endFrame: frames(min(r.endQ, $0.startQ + $0.durationQ) - r.startQ),
                                 pitch: UInt8(clamping: $0.pitch), velocity: UInt8(clamping: $0.velocity)) }
        e.configure(sampleRate: 44100)
        e.setTracks([])
        e.setMetronome(MetronomeConfig())
        e.setLength(frames(r.endQ - r.startQ))
        e.setMidi(notes, enabled: true)
        e.setMidiMix(muted: false, solo: false)
        e.setLoop(loop ? 0..<frames(r.endQ - r.startQ) : nil)
        playOrigin = (r.sections.lowerBound, r.startQ)
        e.play(from: 0)
    }

    @ViewState private var playOrigin: (Int, Double) = (0, 0)

    private func playheadQ(for section: Int) -> Double? {
        guard transport.isPlaying else { return nil }
        let q = Double(transport.positionFrame) / 44100 * project.bpm / 60 + playOrigin.1
        // Map the elapsed Q back into the section being shown.
        let absQ = PlaygroundOps.sectionStartQ(project, index: playOrigin.0) + q
        let s0 = PlaygroundOps.sectionStartQ(project, index: section)
        let len = PlaygroundOps.sectionLengthQ(project, project.sections[section])
        return absQ >= s0 && absQ < s0 + len ? absQ - s0 : nil
    }

    private func writeMidi() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data]
        panel.nameFieldStringValue = project.title + ".mid"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? PlaygroundOps.exportMidi(project).write(to: url)
    }
}

/// One section: bar grid with blocks. Drag to move, drag the right edge to resize
/// (inner timing scales). Overlaps are shown, never silently resolved.
struct SectionLane: View {
    @Binding var project: PlaygroundProject
    var index: Int
    @Binding var selectedBlock: UUID?
    @Binding var selectedSection: Int
    var pxPerBeat: CGFloat
    var playheadQ: Double?
    @ViewState private var dragStart: [UUID: (Double, Double)] = [:]

    private var section: PlaygroundSection { project.sections[index] }
    private var qPerBar: Double { project.meter.quarterBeatsPerBar }
    private var lengthQ: Double { Double(section.barCount) * qPerBar }

    var body: some View {
        let conflicts = Set(PlaygroundOps.conflicts(in: section).flatMap { [$0.0, $0.1] })
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("乐段名", text: $project.sections[index].name).textFieldStyle(.plain).font(.system(size: 14, weight: .semibold)).frame(width: 140)
                Text("小节").font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize()
                Picker("", selection: Binding(get: { [4, 8, 16, 32].contains(section.barCount) ? section.barCount : 0 }, set: { if $0 > 0 { setBars($0) } })) {
                    ForEach([4, 8, 16, 32], id: \.self) { Text("\($0)").tag($0) }
                    if ![4, 8, 16, 32].contains(section.barCount) { Text("自定").tag(0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Stepper("\(section.barCount)", value: Binding(get: { section.barCount }, set: { setBars($0) }), in: 1...256).fixedSize()
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("前移乐段")
                Button { move(1) } label: { Image(systemName: "arrow.down") }.disabled(index == project.sections.count - 1).help("后移乐段")
                Button(role: .destructive) { project.sections.remove(at: index); selectedSection = max(0, min(selectedSection, project.sections.count - 1)) } label: { Image(systemName: "trash") }
                    .disabled(project.sections.count <= 1)
            }
            .buttonStyle(.borderless)
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        for bar in 0...section.barCount {
                            let x = CGFloat(Double(bar) * qPerBar) * pxPerBeat
                            ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Theme.controlBorder.opacity(0.5)))
                            if bar < section.barCount {
                                ctx.draw(Text("\(bar + 1)").font(.system(size: 9)).foregroundColor(Theme.textSecondary), at: CGPoint(x: x + 8, y: 8))
                                for b in 1..<Int(qPerBar) {
                                    let bx = x + CGFloat(b) * pxPerBeat
                                    ctx.fill(Path(CGRect(x: bx, y: 16, width: 0.5, height: size.height - 16)), with: .color(Theme.controlBorder.opacity(0.18)))
                                }
                            }
                        }
                        if let q = playheadQ {
                            ctx.fill(Path(CGRect(x: CGFloat(q) * pxPerBeat, y: 0, width: 1.5, height: size.height)), with: .color(Theme.accent))
                        }
                    }
                    .frame(width: CGFloat(lengthQ) * pxPerBeat + 2, height: 76)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedBlock = nil; selectedSection = index }
                    ForEach(section.blocks) { b in block(b, conflict: conflicts.contains(b.id)) }
                }
                .frame(height: 76)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(index == selectedSection ? Theme.surface : Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(index == selectedSection ? Theme.accent.opacity(0.4) : Theme.borderSubtle))
            if !conflicts.isEmpty {
                HStack {
                    Label("有重叠的和弦块", systemImage: "exclamationmark.triangle").font(.caption12).foregroundStyle(Theme.error)
                    Button("把重叠块顺移到后面") { resolveByShifting() }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
            if section.blocks.contains(where: { $0.endQ > lengthQ + 1e-6 }) {
                HStack {
                    Label("有块超出乐段末尾", systemImage: "exclamationmark.triangle").font(.caption12).foregroundStyle(Theme.warning)
                    Button("延长乐段") { setBars(Int(ceil((section.blocks.map(\.endQ).max() ?? 0) / qPerBar))) }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
        }
    }

    private func block(_ b: ChordBlock, conflict: Bool) -> some View {
        let selected = selectedBlock == b.id
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Theme.accent : Theme.chipFill)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(conflict ? Theme.error : .clear, lineWidth: 2))
            VStack(alignment: .leading, spacing: 1) {
                Text(b.symbol).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(b.voicingMode == .original ? "原曲" : "标准").font(.system(size: 9))
                if b.simplified { Text("简化").font(.system(size: 9)) }
            }
            .foregroundStyle(selected ? Theme.onAccent : Theme.chipText).padding(.horizontal, 6)
            HStack { Spacer(); Rectangle().fill(Theme.chipLine).frame(width: 4)
                .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture().onChanged { v in resize(b, v.translation.width) }.onEnded { _ in dragStart[b.id] = nil })
            }
        }
        .frame(width: max(12, CGFloat(b.durationQ) * pxPerBeat), height: 52)
        .offset(x: CGFloat(b.startQ) * pxPerBeat, y: 18)
        .onTapGesture { selectedBlock = b.id; selectedSection = index; preview(b) }
        .gesture(DragGesture(minimumDistance: 3).onChanged { v in moveBlock(b, v.translation.width) }.onEnded { _ in dragStart[b.id] = nil })
        .contextMenu {
            Button("删除") { project.sections[index].blocks.removeAll { $0.id == b.id } }
            Button(b.voicingMode == .original ? "改为标准按法" : "改为原曲按法") { mutate(b.id) { $0.voicingMode = $0.voicingMode == .original ? .standard : .original } }
        }
    }

    private func snap(_ q: Double) -> Double { (q * 4).rounded() / 4 }

    private func moveBlock(_ b: ChordBlock, _ dx: CGFloat) {
        if dragStart[b.id] == nil { dragStart[b.id] = (b.startQ, b.durationQ) }
        let s0 = dragStart[b.id]!.0
        mutate(b.id) { $0.startQ = max(0, snap(s0 + Double(dx / pxPerBeat))) }
    }

    private func resize(_ b: ChordBlock, _ dx: CGFloat) {
        if dragStart[b.id] == nil { dragStart[b.id] = (b.startQ, b.durationQ) }
        let d0 = dragStart[b.id]!.1
        mutate(b.id) { $0.durationQ = max(0.25, snap(d0 + Double(dx / pxPerBeat))) }
    }

    private func mutate(_ id: UUID, _ f: (inout ChordBlock) -> Void) {
        guard let i = project.sections[index].blocks.firstIndex(where: { $0.id == id }) else { return }
        f(&project.sections[index].blocks[i])
    }

    private func setBars(_ n: Int) { project.sections[index].barCount = max(1, n) }

    private func move(_ d: Int) {
        let j = index + d
        guard j >= 0, j < project.sections.count else { return }
        project.sections.swapAt(index, j)
        selectedSection = j
    }

    private func resolveByShifting() {
        var blocks = project.sections[index].blocks.sorted { $0.startQ < $1.startQ }
        for i in 1..<max(1, blocks.count) where blocks[i].startQ < blocks[i - 1].endQ { blocks[i].startQ = blocks[i - 1].endQ }
        project.sections[index].blocks = blocks
    }

    private func preview(_ b: ChordBlock) {
        let spb = 60 / project.bpm
        AudioEngine.shared.playNotes(PlaygroundOps.sounding(b).map { (pitch: $0.pitch, start: $0.startQ * spb, duration: $0.durationQ * spb, velocity: $0.velocity) })
    }
}

/// Manual chord picker (root first, then quality), collections and block inspector.
struct MaterialPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var project: PlaygroundProject
    @Binding var selectedSection: Int
    @Binding var selectedBlock: UUID?
    @ViewState private var root = 0
    @ViewState private var quality = ""
    @ViewState private var lengthBars = 1.0
    @ViewState private var message: String?

    private let qualities: [(String, String)] = [("大三", ""), ("小三", "m"), ("大七", "maj7"), ("小七", "m7"), ("属七", "7"),
                                                  ("增", "aug"), ("减", "dim"), ("半减七", "m7♭5"), ("减七", "dim7"), ("sus4", "sus4"),
                                                  ("6", "6"), ("m6", "m6"), ("9", "9"), ("maj9", "maj9"), ("m9", "m9"), ("13", "13"),
                                                  ("7♭9", "7♭9"), ("7♯9", "7♯9"), ("add9", "add9"), ("6/9", "6/9")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let (si, b) = selected { inspector(si, b) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("手动选择和弦").font(.system(size: 13, weight: .semibold))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                        ForEach(0..<12, id: \.self) { pc in
                            Button(Pitch.name(pc: pc, key: project.key)) { root = pc; audition() }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(root == pc ? Theme.accent : .clear, lineWidth: 1.5))
                        }
                    }
                    FlowLayout(spacing: 4) {
                        ForEach(qualities, id: \.1) { name, suf in
                            Button(name) { quality = suf; audition() }.buttonStyle(SecondaryButtonStyle(compact: true))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(quality == suf ? Theme.accent : .clear, lineWidth: 1.5))
                        }
                    }
                    let sym = ChordSymbol.make(root: root, suffix: quality, bass: nil, key: project.key)
                    Text(sym).font(.system(size: 16, weight: .semibold))
                    KeyboardView(pitches: StandardVoicing.pitches(symbol: sym) ?? [], height: 54)
                    Stepper("长度 \(String(format: "%g", lengthBars)) 小节", value: $lengthBars, in: 0.25...8, step: 0.25)
                    Button("加入当前乐段") { addManual() }.buttonStyle(PrimaryButtonStyle())
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("学习收藏").font(.system(size: 13, weight: .semibold))
                    let cols = model.collections()
                    if cols.isEmpty { Text("在和弦卡菜单里「加入学习收藏」后会出现在这里。").font(.caption12).foregroundStyle(Theme.textSecondary) }
                    ForEach(cols) { c in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(c.title).font(.control13)
                                Text(c.items.map(\.symbol).joined(separator: " ")).font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            }
                            Spacer()
                            Button("加入") { addCollection(c) }.buttonStyle(SecondaryButtonStyle(compact: true))
                        }
                    }
                }
                Text("原曲和弦、完整进行、骨架：在片段笔记页的和弦卡或骨架区选择「送入 Playground」。").font(.caption12).foregroundStyle(Theme.textSecondary)
                if let message { Text(message).font(.caption12).foregroundStyle(Theme.warning) }
            }
            .padding(14)
        }
        .background(Theme.surface)
    }

    private var selected: (Int, ChordBlock)? {
        for (i, s) in project.sections.enumerated() { if let b = s.blocks.first(where: { $0.id == selectedBlock }) { return (i, b) } }
        return nil
    }

    private func inspector(_ si: Int, _ b: ChordBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("所选和弦块").font(.system(size: 13, weight: .semibold))
            Text(b.symbol).font(.system(size: 16, weight: .semibold))
            KeyboardView(pitches: Array(Set(PlaygroundOps.sounding(b).map(\.pitch))).sorted(), height: 50)
            Picker("", selection: Binding(get: { b.voicingMode }, set: { m in mutate(si, b.id) { $0.voicingMode = m } })) {
                Text("原曲按法").tag(VoicingMode.original); Text("标准按法").tag(VoicingMode.standard)
            }.pickerStyle(.segmented)
            HStack {
                Button("降八度") { shiftOctave(si, b, -1) }.buttonStyle(SecondaryButtonStyle(compact: true))
                Button("升八度") { shiftOctave(si, b, 1) }.buttonStyle(SecondaryButtonStyle(compact: true))
            }
            Text("来源：\(sourceText(b.source))").font(.caption12).foregroundStyle(Theme.textSecondary)
            if let aid = b.source.analysisId, model.item(aid) != nil {
                Button("回到来源") { model.route = .analysis(aid) }.buttonStyle(.borderless).font(.caption12)
            }
            if b.transposeSemitones != 0 { Text("已移调 \(b.transposeSemitones > 0 ? "+" : "")\(b.transposeSemitones) 半音（不自动调式重配）").font(.caption12).foregroundStyle(Theme.textSecondary) }
            Button("删除块", role: .destructive) { project.sections[si].blocks.removeAll { $0.id == b.id }; selectedBlock = nil }
                .buttonStyle(.borderless)
            Divider()
        }
    }

    private func sourceText(_ s: BlockSource) -> String {
        let kind = ["chord": "原曲和弦", "progression": "完整进行", "skeleton": "骨架（简化）", "collection": "收藏", "manual": "手动选择"][s.kind] ?? s.kind
        return kind + " · " + s.label
    }

    private func mutate(_ si: Int, _ id: UUID, _ f: (inout ChordBlock) -> Void) {
        guard let i = project.sections[si].blocks.firstIndex(where: { $0.id == id }) else { return }
        f(&project.sections[si].blocks[i])
    }

    /// Whole-instance octave move; individual notes are never folded.
    private func shiftOctave(_ si: Int, _ b: ChordBlock, _ d: Int) {
        let pitches = b.originalNotes.map { $0.pitch + d * 12 }
        guard (pitches.min() ?? 0) >= 0, (pitches.max() ?? 0) <= 127 else { message = "再移就超出 MIDI 音域了"; return }
        mutate(si, b.id) { blk in
            blk.originalNotes = blk.originalNotes.map { var n = $0; n.pitch += d * 12; return n }
            blk.octaveShift += d
        }
    }

    private func audition() {
        AudioEngine.shared.stopChord()
        let sym = ChordSymbol.make(root: root, suffix: quality, bass: nil, key: project.key)
        if let p = StandardVoicing.pitches(symbol: sym) { AudioEngine.shared.playChord(p) }
    }

    private func addManual() {
        guard !project.sections.isEmpty else { return }
        let si = min(selectedSection, project.sections.count - 1)
        let dur = lengthBars * project.meter.quarterBeatsPerBar
        guard var b = PlaygroundOps.manualBlock(rootPc: root, suffix: quality, target: project.key, durationQ: dur) else { return }
        let len = PlaygroundOps.sectionLengthQ(project, project.sections[si])
        if let s = PlaygroundOps.freeStart(in: project.sections[si], length: dur, sectionLength: len) {
            b.startQ = s
        } else {
            b.startQ = project.sections[si].blocks.map(\.endQ).max() ?? 0
            project.sections[si].barCount = Int(ceil((b.startQ + dur) / project.meter.quarterBeatsPerBar))
            message = "乐段已延长以放下这个和弦"
        }
        project.sections[si].blocks.append(b)
        selectedBlock = b.id
    }

    private func addCollection(_ c: LearningCollection) {
        let si = min(selectedSection, project.sections.count - 1)
        var keys: [UUID: KeySignature] = [:]
        for it in c.items { if let k = model.item(it.analysisId)?.timing?.key { keys[it.analysisId] = k } }
        do {
            let blocks = try PlaygroundOps.collectionBlocks(c.items, target: project.key, sourceKeys: keys)
            let start = project.sections[si].blocks.map(\.endQ).max() ?? 0
            let total = blocks.map(\.endQ).max() ?? 0
            let len = PlaygroundOps.sectionLengthQ(project, project.sections[si])
            if start + total > len { project.sections[si].barCount = Int(ceil((start + total) / project.meter.quarterBeatsPerBar)) }
            for var b in blocks { b.startQ += start; project.sections[si].blocks.append(b) }
        } catch { message = error.localizedDescription }
    }
}
