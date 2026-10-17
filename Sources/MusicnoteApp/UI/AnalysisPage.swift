import AVFoundation
import MusicnoteCore
import SwiftUI

/// Loaded audio for the selection/confirmation stages.
@MainActor @Observable
final class SourceSession {
    var buffer: AVAudioPCMBuffer?
    var peaks: WaveformPeaks?
    var error: String?
    var loading = false
    var loadedFor: String?

    func load(_ source: SourceRef) {
        guard loadedFor != source.fingerprint, !loading else { return }
        guard let url = Pipeline.resolve(source) else { error = "原曲文件找不到了"; return }
        loading = true
        error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let buf = try AudioLoader.load(url)
                let peaks = WaveformPeaks(buffer: buf)
                await MainActor.run {
                    self.buffer = buf; self.peaks = peaks; self.loading = false; self.loadedFor = source.fingerprint
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; self.loading = false }
            }
        }
    }
}

struct AnalysisPage: View {
    @Environment(AppModel.self) private var model
    let itemId: UUID
    @ViewState private var source = SourceSession()
    @ViewState private var transport = TransportModel()

    var body: some View {
        let _ = model.dataVersion
        if let item = model.item(itemId) {
            VStack(spacing: 0) {
                AnalysisHeader(item: item)
                Divider()
                Group {
                    switch item.state {
                    case .draft, .detecting:
                        SelectionStage(item: item, source: source, transport: transport)
                    case .awaitingConfirmation:
                        ConfirmStage(item: item, source: source, transport: transport)
                    case .separating, .transcribing, .harmonizing:
                        ProgressStage(item: item)
                    case .awaitingStem:
                        StemStage(item: item, transport: transport)
                    case .editingMidi:
                        MidiStage(item: item, transport: transport)
                    case .ready:
                        ReadyStage(item: item, transport: transport)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { if item.state.needsSource { source.load(item.source) } }
            .onChange(of: item.state) { _, s in if s.needsSource { source.load(item.source) } }
            .onDisappear { AudioEngine.shared.stopAll(); transport.stop() }
        }
    }
}

extension AnalysisState {
    var needsSource: Bool { self == .draft || self == .detecting || self == .awaitingConfirmation }
    var step: Int {
        switch self {
        case .draft, .detecting: 0
        case .awaitingConfirmation: 1
        case .separating, .awaitingStem: 2
        case .transcribing, .editingMidi: 3
        case .harmonizing, .ready: 4
        }
    }
}

struct AnalysisHeader: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    @ViewState private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TextField("片段标题", text: $title).font(.pageTitle).textFieldStyle(.plain)
                    .onSubmit { var i = item; i.title = title; model.save(i) }
                    .onAppear { title = item.title }
                Spacer()
                if let song = model.song(item.songId) {
                    Button(song.title) { model.route = .song(song.id) }.buttonStyle(.borderless).font(.control13)
                }
            }
            HStack(spacing: 10) {
                Text("\(item.source.fileName) · \(formatTime(us: item.trimStartUs))–\(formatTime(us: item.trimEndUs))（\(String(format: "%.3f", item.durationUs.seconds)) 秒）")
                    .font(.caption12).foregroundStyle(Theme.textSecondary)
                if Pipeline.resolve(item.source) == nil {
                    Label("原曲已移动或删除", systemImage: "exclamationmark.triangle").font(.caption12).foregroundStyle(Theme.warning)
                    Button("重新选择原曲…") { model.relinkSource(item.id) }.buttonStyle(.borderless).font(.caption12)
                }
                Spacer()
                StepIndicator(step: item.state.step, harmonic: item.selectedStem.map(\.isHarmonic) ?? true)
            }
            if let job = model.jobs[item.id] {
                HStack(spacing: 8) {
                    ProgressView(value: job.total.map { Double(job.completed) / Double(max(1, $0)) }).frame(width: 160)
                        .progressViewStyle(.linear)
                    Text(job.stage + (job.total.map { "（\(job.completed)/\($0)）" } ?? "")).font(.caption12)
                    Button("取消") { model.cancelJob(item.id) }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
            } else if let failed = model.failedJob(for: item.id) {
                HStack(spacing: 8) {
                    Image(systemName: failed.status == .interrupted ? "pause.circle" : "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    Text((failed.status == .interrupted ? "上次任务被中断：" : "任务失败：") + (failed.errorMessage ?? failed.type.rawValue))
                        .font(.caption12).foregroundStyle(Theme.warning).lineLimit(2)
                    Button("重试") { retry(failed) }.buttonStyle(SecondaryButtonStyle(compact: true))
                    Button("丢弃") { model.discardJob(failed) }.buttonStyle(.borderless).font(.caption12)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func retry(_ job: Job) {
        model.discardJob(job)
        switch job.type {
        case .detect: model.analyze(item.id)
        case .separate: if let t = item.timing { model.confirmAndSeparate(item.id, timing: t) }
        case .transcribe: if let s = item.selectedStem { model.transcribe(item.id, stem: s) }
        case .harmony: model.runHarmony(item.id)
        case .skeleton: model.generateSkeleton(item.id)
        }
    }
}

struct StepIndicator: View {
    var step: Int
    var harmonic: Bool
    var body: some View {
        let names = ["选区", "速度调性", "拆轨选轨", "MIDI 校对", harmonic ? "和声与笔记" : "笔记"]
        HStack(spacing: 4) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                Text(n).font(.system(size: 11, weight: i == step ? .semibold : .regular))
                    .foregroundStyle(i == step ? Theme.accent : (i < step ? Theme.textPrimary : Theme.textSecondary))
                if i < names.count - 1 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.textSecondary) }
            }
        }
    }
}

// MARK: - Selection

struct SelectionStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var source: SourceSession
    var transport: TransportModel
    @ViewState private var selection: Range<Int64> = 0..<1
    @ViewState private var viewRange: Range<Int64> = 0..<1
    @ViewState private var loopOn = false
    @ViewState private var stopAt: Int64?

    private var rate: Double { item.source.sampleRate }
    private func frame(_ us: Int64) -> Int64 { Int64((Double(us) * rate / 1_000_000).rounded()) }
    private func us(_ f: Int64) -> Int64 { Int64((Double(f) / rate * 1_000_000).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let e = source.error {
                Card { HStack { Text(e).foregroundStyle(Theme.warning); Button("重新选择原曲…") { model.relinkSource(item.id) } } }
            }
            SectionHeader(title: "圈出想学的片段", subtitle: "拖两侧边界调整起止，拖中间整体平移。拖动不会触发分析。")
            WaveformSelectionView(peaks: source.peaks, totalFrames: item.source.frames, selection: $selection,
                                  playhead: transport.positionFrame, editable: item.state == .draft, viewRange: $viewRange,
                                  onSeek: { AudioEngine.shared.seek($0) }, onCommit: commit)
                .frame(height: 180)
                .overlay { if source.loading { ProgressView("正在读取整曲波形…") } }
            ZoomBar(viewRange: $viewRange, totalFrames: item.source.frames, anchor: transport.positionFrame, fitRange: selection)
            HStack(spacing: 18) {
                TimeField(label: "起点", us: us(selection.lowerBound)) { v in setRange(frame(v), selection.upperBound) }
                TimeField(label: "终点", us: us(selection.upperBound)) { v in setRange(selection.lowerBound, frame(v)) }
                TimeField(label: "时长", us: us(Int64(selection.count))) { v in setRange(selection.lowerBound, selection.lowerBound + frame(v)) }
                Spacer()
            }
            .disabled(item.state != .draft)
            HStack(spacing: 8) {
                Button { playSelection() } label: { Label("播放选区", systemImage: "play.fill") }.buttonStyle(SecondaryButtonStyle())
                Button { AudioEngine.shared.play(from: transport.positionFrame) } label: { Label("从游标播放", systemImage: "play") }
                    .buttonStyle(SecondaryButtonStyle())
                Button { AudioEngine.shared.pause() } label: { Label("停止", systemImage: "stop.fill") }.buttonStyle(SecondaryButtonStyle())
                Toggle("循环选区", isOn: $loopOn).toggleStyle(.checkbox)
                Spacer()
                if item.state == .detecting {
                    ProgressView().controlSize(.small)
                    Text("正在只分析选区的 BPM 与调性（未拆轨）").font(.caption12)
                } else {
                    Button("分析 BPM 与调性") { commit(); model.analyze(item.id) }
                        .buttonStyle(PrimaryButtonStyle()).disabled(selection.count < Int(rate * 0.5) || source.buffer == nil)
                        .help("锁定当前区间并启动 Essentia。此时不会拆轨。")
                }
            }
            Text("显示精度到毫秒；实际裁剪按解码后的采样位置。").font(.caption12).foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(24)
        .onAppear(perform: setup)
        .onChange(of: source.buffer != nil) { _, _ in setup() }
        .onChange(of: loopOn) { _, on in AudioEngine.shared.setLoop(on ? selection : nil) }
        .onChange(of: selection) { _, s in if loopOn { AudioEngine.shared.setLoop(s) } }
        .onChange(of: transport.positionFrame) { _, p in
            if let stop = stopAt, p >= stop, !loopOn { AudioEngine.shared.pause(); stopAt = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in
            if AudioEngine.shared.isPlaying { AudioEngine.shared.pause() } else { playSelection() }
        }
    }

    private func setup() {
        selection = frame(item.trimStartUs)..<max(frame(item.trimStartUs) + 1, frame(item.trimEndUs))
        if viewRange.count <= 1 { viewRange = 0..<max(1, item.source.frames) }
        guard let buf = source.buffer else { return }
        transport.sampleRate = rate
        let e = AudioEngine.shared
        e.pause()
        e.configure(sampleRate: rate)
        e.setMidi([], enabled: false)
        e.setMetronome(MetronomeConfig())
        e.setTracks([AudioTrack(id: "source", buffer: buf)])
        e.setLength(item.source.frames)
        e.seek(selection.lowerBound)
    }

    private func setRange(_ s: Int64, _ e: Int64) {
        let s2 = max(0, min(s, item.source.frames - 1))
        let e2 = max(s2 + 1, min(e, item.source.frames))
        selection = s2..<e2
        commit()
    }

    private func commit() { model.updateSelection(item.id, start: us(selection.lowerBound), end: us(selection.upperBound)) }

    private func playSelection() {
        stopAt = loopOn ? nil : selection.upperBound
        AudioEngine.shared.setLoop(loopOn ? selection : nil)
        AudioEngine.shared.play(from: selection.lowerBound)
    }
}

/// Seconds with millisecond display; accepts "1:23.456" or "83.456".
struct TimeField: View {
    var label: String
    var us: Int64
    var onCommit: (Int64) -> Void
    @ViewState private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption12).foregroundStyle(Theme.textSecondary)
            TextField("", text: $text).font(.mono13).frame(width: 96).textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let v = parse(text) { onCommit(v) } }
        }
        .onAppear { text = formatTime(us: us) }
        .onChange(of: us) { _, v in if !focused { text = formatTime(us: v) } }
    }

    private func parse(_ s: String) -> Int64? {
        let parts = s.split(separator: ":")
        var sec = 0.0
        if parts.count == 2, let m = Double(parts[0]), let x = Double(parts[1]) { sec = m * 60 + x }
        else if let x = Double(s) { sec = x } else { return nil }
        return sec >= 0 ? Int64(sec * 1_000_000) : nil
    }
}

// MARK: - Progress

struct ProgressStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            if let j = model.jobs[item.id] {
                Text(j.stage).font(.sectionTitle)
                if let t = j.total { Text("\(j.completed) / \(t)").font(.mono13).foregroundStyle(Theme.textSecondary) }
                Button("取消") { model.cancelJob(item.id) }.buttonStyle(SecondaryButtonStyle())
            } else {
                Text(item.state.display).font(.sectionTitle)
                Text("任务没有在运行。可在上方重试或丢弃。").font(.caption12).foregroundStyle(Theme.textSecondary)
                fallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var fallback: some View {
        switch item.state {
        case .separating: Button("回到速度调性确认") { var i = item; i.state = .awaitingConfirmation; model.save(i) }.buttonStyle(SecondaryButtonStyle())
        case .transcribing: Button("回到选轨") { var i = item; i.state = .awaitingStem; model.save(i) }.buttonStyle(SecondaryButtonStyle())
        case .harmonizing: Button("重新分析和声") { model.runHarmony(item.id) }.buttonStyle(SecondaryButtonStyle())
        default: EmptyView()
        }
    }
}

// MARK: - Stems

struct StemStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var transport: TransportModel
    @ViewState private var chosen: StemKind?
    @ViewState private var listening: StemKind?
    @ViewState private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "试听并单选一条分轨", subtitle: "六条均为 192 kbps MP3。切换试听保持同一播放位置。只有钢琴、吉他、其他轨进入和声分析。")
            if let sep = item.separation {
                VStack(spacing: 0) {
                    ForEach(StemKind.allCases, id: \.self) { kind in
                        if let s = sep.stem(kind) { row(kind, s); Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderSubtle))
                HStack(spacing: 8) {
                    Button { toggle() } label: { Label(transport.isPlaying ? "暂停" : "播放", systemImage: transport.isPlaying ? "pause.fill" : "play.fill") }
                        .buttonStyle(SecondaryButtonStyle())
                    Text(formatTime(us: transport.positionUs)).font(.mono13).foregroundStyle(Theme.textSecondary)
                    Text("共享增益 \(String(format: "%.2f", sep.sharedGainDb)) dB").font(.caption12).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("转为 MIDI") { if let c = chosen { AudioEngine.shared.pause(); model.transcribe(item.id, stem: c) } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(chosen == nil)
                }
                Text("完成 MIDI 校对前，六条候选都会保留，可以改选另一轨重新转录；完成校对后才清理未选的分轨。")
                    .font(.caption12).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(24)
        .onAppear { chosen = item.selectedStem; load() }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in toggle() }
    }

    private func row(_ kind: StemKind, _ s: StemAsset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: chosen == kind ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(chosen == kind ? Theme.accent : Theme.textSecondary)
            Text(kind.displayName).font(.system(size: 14, weight: .medium)).frame(width: 48, alignment: .leading)
            if s.level == .silent { StatusPill(text: "静音", color: Theme.warning) }
            if s.level == .weak { StatusPill(text: "很弱", color: Theme.warning) }
            if !kind.isHarmonic { Text("不做和声分析").font(.caption12).foregroundStyle(Theme.textSecondary) }
            Spacer()
            Text(String(format: "%.1f MB", Double(s.bytes) / 1_000_000)).font(.caption12).foregroundStyle(Theme.textSecondary)
            Button { listen(kind) } label: {
                Label(listening == kind ? "正在试听" : "试听", systemImage: listening == kind ? "speaker.wave.2.fill" : "speaker.wave.2")
            }.buttonStyle(SecondaryButtonStyle(compact: true))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { chosen = kind }
    }

    private func load() {
        guard let sep = item.separation, !loaded else { return }
        let e = AudioEngine.shared
        e.pause(); e.configure(sampleRate: 44100); e.setMidi([], enabled: false); e.setMetronome(MetronomeConfig()); e.setLoop(nil)
        transport.sampleRate = 44100
        var tracks: [AudioTrack] = []
        for s in sep.stems {
            if let buf = try? AudioLoader.load(model.paths.url(relative: s.relativePath)) {
                let t = AudioTrack(id: s.kind.rawValue, buffer: buf)
                tracks.append(t)
            }
        }
        e.setTracks(tracks)
        e.setLength(sep.frames)
        listen(listening ?? chosen ?? .piano, start: false)
        loaded = true
    }

    private func listen(_ kind: StemKind, start: Bool = true) {
        listening = kind
        for k in StemKind.allCases { AudioEngine.shared.updateTrack(k.rawValue, muted: false, solo: k == kind) }
        if start && !AudioEngine.shared.isPlaying { AudioEngine.shared.play() }
    }

    private func toggle() {
        if AudioEngine.shared.isPlaying { AudioEngine.shared.pause() } else { AudioEngine.shared.play() }
    }
}
