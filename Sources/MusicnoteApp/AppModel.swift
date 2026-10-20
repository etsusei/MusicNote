import AppKit
import AVFoundation
import Foundation
import MusicnoteCore
import Observation
import UniformTypeIdentifiers

enum Route: Hashable {
    case song(UUID)
    case analysis(UUID)
    case playground(UUID)
    case settings
    case bookmarks
    case inspirations
}

enum SortMode: String, CaseIterable { case manual = "手动", title = "歌名", recent = "最近编辑" }

struct JobProgress {
    var jobId: UUID
    var type: JobType
    var stage: String
    var completed: Int
    var total: Int?
    var task: Task<Void, Never>?
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var code: String?
}

@MainActor @Observable
final class AppModel {
    let paths: AppPaths
    let store: Store
    var settings: AppSettings
    let pipeline: Pipeline

    var songs: [Song] = []
    var itemsBySong: [UUID: [AnalysisItem]] = [:]
    var playgrounds: [PlaygroundProject] = []
    var route: Route?
    var showLeft = true
    var showRight = true
    var search = ""
    var sortMode: SortMode = .manual
    var tagFilter: Set<String> = []
    var jobs: [UUID: JobProgress] = [:] // by analysisId
    var alert: AppAlert?
    var interruptedJobs: [Job] = []
    /// Bumped whenever analysis data changes so pages reload derived data.
    var dataVersion = 0

    var providers: [String: ChatProvider] = [:]
    var providerStatus: [String: ProviderStatus] = [:]
    var providerModels: [String: [ProviderModel]] = [:]
    var chat: ChatController!
    var autoRuns: [UUID: AutoRun] = [:]
    var autoTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var _autoProvider: CodexProvider?
    @ObservationIgnored var _autoClaude: ClaudeAgentProvider?
    var songGridRunning: Set<UUID> = []
    var draftUndo: [UUID: [DraftUndo]] = [:]
    /// The clip whose original + chords is playing (for highlighting the sounding chord).
    var playAlongItem: UUID?
    /// Shown in the toolbar while a picked video's audio is extracted.
    var importStatus: String?
    /// When each chord sounds during play-along (as the bars show it); the highlight follows these.
    var playAlongSpans: [(id: String, startUs: Int64, endUs: Int64)] = []
    /// What each chord sounds during play-along (the keyboard lights these).
    var playAlongPitches: [String: [Int]] = [:]
    /// The chord lit on the keyboard: the last one clicked or sounded, until the next.
    var litChord: LitChord?
    // 灵感进行
    var inspirationUndo: [InspirationProgression] = []
    var playingInspiration: UUID?
    @ObservationIgnored var activeChordDrag: ChordDragPayload?
    @ObservationIgnored var activeChordDragAt: Date?
    var songGridError: [UUID: String] = [:]
    @ObservationIgnored var auditionCache: [String: AVAudioPCMBuffer] = [:]
    @ObservationIgnored var auditionStop: Task<Void, Never>?

    /// Tests can exercise storage and observation without starting audio or provider login.
    init(startServices: Bool = true) {
        paths = AppPaths(root: ProcessInfo.processInfo.environment["MUSICNOTE_DATA_ROOT"].map { URL(fileURLWithPath: $0) })
        try? paths.ensure()
        let bundleRoot = Bundle.main.object(forInfoDictionaryKey: "MusicnoteProjectRoot") as? String
        let projectRoot = bundleRoot ?? ProcessInfo.processInfo.environment["MUSICNOTE_ROOT"] ?? "/Users/yao/Desktop/musicnote"
        let bundledSeparator = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/musicnote-separate").path
        let separator = FileManager.default.fileExists(atPath: bundledSeparator) ? bundledSeparator : projectRoot + "/.build/debug/musicnote-separate"
        var loaded = AppSettings.load(paths, defaults: ToolSettings.defaults(projectRoot: projectRoot, separatorBinary: separator))
        if !FileManager.default.fileExists(atPath: loaded.tools.separatorBinary) { loaded.tools.separatorBinary = separator }
        let db: Store
        do { db = try Store(url: paths.database) } catch {
            fatalError("无法打开数据库：\(error)")
        }
        settings = loaded
        store = db
        pipeline = Pipeline(store: db, paths: paths, tools: loaded.tools)
        rebuildProviders()
        chat = ChatController(app: self)
        interruptedJobs = pipeline.recoverOnLaunch()
        reload()
        if startServices {
            AudioEngine.shared.loadSoundFont(URL(fileURLWithPath: settings.tools.soundFont))
            AudioEngine.shared.setInstrument(settings.instrument)
            applyTheme()
            Task { await refreshProviders() }
        }
    }

    func rebuildProviders() {
        providers = [
            "codex": CodexProvider(binary: settings.tools.codexBinary, sandboxDir: paths.chatSandbox),
            "claude": ClaudeProvider(binary: settings.tools.claudeBinary, sandboxDir: paths.chatSandbox),
        ]
    }

    func saveSettings() {
        settings.save(paths)
        pipeline.tools = settings.tools
        AudioEngine.shared.setInstrument(settings.instrument)
        applyTheme()
    }

    func applyTheme() {
        switch settings.theme {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }

    func refreshProviders() async {
        for (id, p) in providers {
            providerStatus[id] = ProviderStatus(state: .connecting)
            let s = await p.status()
            providerStatus[id] = s
            if s.state == .connected || s.state == .quotaExhausted { providerModels[id] = await p.models() }
        }
    }

    // MARK: Library

    func reload() {
        songs = store.all(Song.self)
        var by: [UUID: [AnalysisItem]] = [:]
        for i in store.all(AnalysisItem.self) { by[i.songId, default: []].append(i) }
        itemsBySong = by
        playgrounds = store.all(PlaygroundProject.self).sorted { $0.updatedAt > $1.updatedAt }
        dataVersion += 1
    }

    func item(_ id: UUID) -> AnalysisItem? { store.fetch(AnalysisItem.self, id: id) }
    func song(_ id: UUID) -> Song? { songs.first { $0.id == id } }
    func items(of song: UUID) -> [AnalysisItem] { (itemsBySong[song] ?? []).sorted { $0.sortIndex < $1.sortIndex } }

    var allTags: [String] {
        var s = Set<String>()
        for song in songs { s.formUnion(song.tags) }
        for list in itemsBySong.values { for i in list { s.formUnion(i.tags); s.formUnion(i.skeletonTags) } }
        return s.sorted()
    }

    /// Search over song title/artist, item titles, notes and tags; tag filter is OR within the set.
    var visibleSongs: [Song] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var list = songs.filter { song in
            let items = itemsBySong[song.id] ?? []
            if !tagFilter.isEmpty {
                let tags = Set(song.tags + items.flatMap { $0.tags + $0.skeletonTags }).map(TagText.normalize)
                if tagFilter.map(TagText.normalize).allSatisfy({ !tags.contains($0) }) { return false }
            }
            guard !q.isEmpty else { return true }
            if song.title.lowercased().contains(q) || song.artist.lowercased().contains(q) { return true }
            if song.tags.contains(where: { TagText.normalize($0).contains(TagText.normalize(q)) }) { return true }
            for i in items {
                if i.title.lowercased().contains(q) { return true }
                if (i.tags + i.skeletonTags).contains(where: { TagText.normalize($0).contains(TagText.normalize(q)) }) { return true }
                if let doc = store.fetch(NoteDocument.self, id: i.id), doc.text.lowercased().contains(q) { return true }
            }
            return false
        }
        switch sortMode {
        case .manual: list.sort { $0.sortIndex < $1.sortIndex }
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recent:
            func last(_ s: Song) -> Date { ([s.updatedAt] + (itemsBySong[s.id] ?? []).map(\.updatedAt)).max()! }
            list.sort { last($0) > last($1) }
        }
        return list
    }

    /// Audio files, or videos (their audio track is extracted on import).
    func pickAudio(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "可以选音频，也可以选视频（会提取视频里的音轨）"
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio, .movie, .video]
            + Pipeline.videoExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A picked file as a source: audio as it is; for a video, its extracted audio track
    /// (shown as "<video> 的音轨").
    func importSource(_ url: URL) async throws -> SourceRef {
        guard Pipeline.isVideo(url) else { return try Pipeline.inspectSource(url: url) }
        importStatus = "正在提取视频音轨：\(url.lastPathComponent)"
        defer { importStatus = nil }
        let audio = try await pipeline.extractVideoAudio(url)
        var s = try Pipeline.inspectSource(url: audio)
        s.fileName = url.lastPathComponent + " 的音轨"
        return s
    }

    /// Files dropped in: each audio or video becomes a song (the last one opens).
    func importDropped(_ urls: [URL]) {
        let media = urls.filter(MediaFileDrop.isMedia)
        if media.count < urls.count {
            alert = AppAlert(title: "有文件没导入", message: "只能导入音频或视频：" + urls.filter { !MediaFileDrop.isMedia($0) }.map(\.lastPathComponent).joined(separator: "、"))
        }
        Task { for u in media { await createSong(from: u) } }
    }

    /// A file dropped on a song: a new clip of it.
    func addDroppedAnalysis(to song: Song, _ urls: [URL]) {
        guard let u = urls.first(where: MediaFileDrop.isMedia) else {
            alert = AppAlert(title: "没有导入", message: "只能拖入音频或视频文件。"); return
        }
        Task { await addAnalysis(to: song, from: u) }
    }

    func addSong() {
        guard let url = pickAudio(title: "选择本地原曲（音频或视频）") else { return }
        Task { await createSong(from: url) }
    }

    func createSong(from url: URL) async {
        do {
            let source = try await importSource(url)
            let meta = await Pipeline.readMetadata(url: url)
            var song = Song(title: meta.title ?? url.deletingPathExtension().lastPathComponent, artist: meta.artist ?? "",
                            album: meta.album ?? "", sortIndex: (songs.map(\.sortIndex).max() ?? 0) + 1)
            if let art = meta.artwork {
                let name = song.id.uuidString + ".img"
                try? art.write(to: paths.covers.appendingPathComponent(name))
                song.coverFile = name
            }
            try store.save(song)
            let item = AnalysisItem(songId: song.id, title: "片段 1", source: source, trimStartUs: 0,
                                    trimEndUs: Int64(min(source.durationSec, 30) * 1_000_000))
            try store.save(item)
            reload()
            route = .analysis(item.id)
            warnIfShort(source)
        } catch { report(error) }
    }

    /// 新增分析: re-select the user's original file; a new item never reuses the last range.
    func addAnalysis(to song: Song) {
        guard let url = pickAudio(title: "重新选择原曲（\(song.title)）") else { return }
        Task { await addAnalysis(to: song, from: url) }
    }

    func addAnalysis(to song: Song, from url: URL) async {
        do {
            let source = try await importSource(url)
            let existing = items(of: song.id).first?.source
            if let existing, existing.fingerprint != source.fingerprint {
                alert = AppAlert(title: "可能不是同一来源", message: "所选文件与这首歌已有片段的来源指纹不同（\(existing.fileName)）。已按新文件创建分析，请确认。")
            }
            let n = items(of: song.id).count + 1
            let item = AnalysisItem(songId: song.id, title: "片段 \(n)", source: source, trimStartUs: 0,
                                    trimEndUs: Int64(min(source.durationSec, 30) * 1_000_000))
            try store.save(item)
            reload()
            route = .analysis(item.id)
            if alert == nil { warnIfShort(source) }
        } catch { report(error) }
    }

    /// A source of 35 s or less is most likely a store preview, not the song.
    func warnIfShort(_ s: SourceRef) {
        guard s.durationSec <= 35 else { return }
        alert = AppAlert(title: "这个文件只有 \(Int(s.durationSec.rounded())) 秒",
                         message: "\(s.fileName) 可能是试听片段而不是完整的歌。如果有完整版，可以在选区页点“换一个原曲文件…”。")
    }

    /// Before separation nothing is derived from the file yet, so a clip may switch to another
    /// file (e.g. the full song instead of a preview). The selection is kept inside the new file.
    func replaceSource(_ itemId: UUID) {
        guard item(itemId)?.separation == nil, let url = pickAudio(title: "换一个原曲文件") else { return }
        Task { await replaceSource(itemId, with: url) }
    }

    private func replaceSource(_ itemId: UUID, with url: URL) async {
        guard var item = item(itemId) else { return }
        do {
            let s = try await importSource(url)
            item.source = s
            let total = Int64(s.durationSec * 1_000_000)
            item.trimStartUs = min(item.trimStartUs, max(0, total - 1_000_000))
            item.trimEndUs = min(max(item.trimEndUs, item.trimStartUs + 1_000_000), total)
            item.trimRevision += 1
            item.detection = nil
            item.timing = nil
            item.songGrid = nil
            item.state = .draft
            save(item)
            warnIfShort(s)
            detectSongGrid(itemId)
        } catch { report(error) }
    }

    func relinkSource(_ itemId: UUID) {
        guard let url = pickAudio(title: "重新选择原曲") else { return }
        Task { await relinkSource(itemId, to: url) }
    }

    private func relinkSource(_ itemId: UUID, to url: URL) async {
        guard var item = item(itemId) else { return }
        do {
            let s = try await importSource(url)
            if s.fingerprint != item.source.fingerprint {
                alert = AppAlert(title: "文件不一致", message: "这个文件和原来的来源不是同一份（大小或内容不同），已保留原引用。")
                return
            }
            item.source = s
            save(item)
        } catch { report(error) }
    }

    func save(_ song: Song) {
        var s = song; s.updatedAt = Date()
        do { try store.save(s); reload() } catch { report(error) }
    }

    func save(_ item: AnalysisItem) {
        var i = item; i.updatedAt = Date()
        do { try store.save(i); reload() } catch { report(error) }
    }

    func deleteSong(_ song: Song) {
        for i in items(of: song.id) { deleteAnalysis(i, reloadAfter: false) }
        try? store.delete(Song.self, id: song.id)
        if let c = song.coverFile { paths.removeOwned(paths.covers.appendingPathComponent(c)) }
        route = nil
        reload()
    }

    /// Removes an item and everything it owns; external source files are never touched.
    func deleteAnalysis(_ item: AnalysisItem, reloadAfter: Bool = true) {
        cancelJob(item.id)
        cancelAutoAnalysis(item.id)
        do {
            // MIDI, harmony, skeletons, jobs, model runs and evidence are all owned by the item.
            try store.transaction { tx in
                try tx.deleteOwned(by: item.id)
                try tx.delete(NoteDocument.self, id: item.id)
                try tx.delete(AnalysisItem.self, id: item.id)
            }
        } catch {
            report(error); return
        }
        paths.removeOwned(paths.analysisAssets(item.id))
        // Audio extracted from a video goes with the last clip that uses it.
        let src = URL(fileURLWithPath: item.source.pathHint)
        if src.path.hasPrefix(paths.videoAudio.path),
           !store.all(AnalysisItem.self).contains(where: { $0.source.pathHint == item.source.pathHint }) {
            paths.removeOwned(src)
        }
        if route == .analysis(item.id) { route = .song(item.songId) }
        if reloadAfter { reload() }
    }

    func report(_ error: Error) {
        let code = (error as? WorkerError)?.code ?? (error as? ProviderError)?.code
        alert = AppAlert(title: "出错了", message: error.localizedDescription, code: code)
    }

    // MARK: Jobs

    private func startJob(_ type: JobType, item: AnalysisItem, revision: Int,
                          body: @escaping (_ job: Job, _ progress: @escaping ProgressHandler) async throws -> Void,
                          onError: @escaping (Error) -> Void) {
        let jobId = UUID()
        var job = Job(type: type, analysisId: item.id, inputRevision: revision, directory: "jobs/\(jobId.uuidString)")
        job.id = jobId
        try? store.save(job)
        let progress: ProgressHandler = { [weak self] p in
            Task { @MainActor in
                guard let self, var j = self.jobs[item.id], j.jobId == jobId else { return }
                j.stage = p.stage; j.completed = p.completed; j.total = p.total
                self.jobs[item.id] = j
            }
        }
        jobs[item.id] = JobProgress(jobId: jobId, type: type, stage: "准备", completed: 0, total: nil)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await body(job, progress)
                job.status = .succeeded
                try? self.store.delete(Job.self, id: jobId)
                self.paths.removeOwned(self.paths.jobDirectory(jobId))
            } catch is CancellationError {
                job.status = .cancelled
                try? self.store.delete(Job.self, id: jobId)
                self.paths.removeOwned(self.paths.jobDirectory(jobId))
                onError(CancellationError())
            } catch {
                job.status = .failed
                job.errorCode = (error as? WorkerError)?.code
                job.errorMessage = error.localizedDescription
                try? self.store.save(job)
                onError(error)
            }
            if self.jobs[item.id]?.jobId == jobId { self.jobs[item.id] = nil }
            self.reload()
        }
        jobs[item.id]?.task = task
    }

    func cancelJob(_ analysisId: UUID) {
        jobs[analysisId]?.task?.cancel()
    }

    func failedJob(for analysisId: UUID) -> Job? {
        store.all(Job.self, owner: analysisId).filter { $0.status == .failed || $0.status == .interrupted }.max { $0.startedAt < $1.startedAt }
    }

    func discardJob(_ job: Job) {
        try? store.delete(Job.self, id: job.id)
        paths.removeOwned(paths.jobDirectory(job.id))
        interruptedJobs.removeAll { $0.id == job.id }
        reload()
    }

    // MARK: Stage 1 – detect

    func analyze(_ itemId: UUID) {
        guard var item = item(itemId), item.durationUs > 0 else { return }
        item.state = .detecting
        save(item)
        startJob(.detect, item: item, revision: item.trimRevision, body: { [weak self] job, progress in
            guard let self else { return }
            let det = try await self.pipeline.detect(item, jobDir: self.paths.jobDirectory(job.id), progress: progress)
            guard var cur = self.item(itemId), cur.trimRevision == det.trimRevision else { return } // stale result
            cur.detection = det
            cur.state = .awaitingConfirmation
            self.save(cur)
        }, onError: { [weak self] error in
            guard let self, var cur = self.item(itemId) else { return }
            // Detection failure still lets the user type values in.
            if !(error is CancellationError) {
                cur.detection = Detection(trimRevision: cur.trimRevision, rawBpm: nil, roundedBpm: nil, ticksSec: [], confidence: nil,
                                          estimates: [], rawKey: nil, rawScale: nil, keyStrength: nil, params: [:], version: "",
                                          errors: [error.localizedDescription], detectedAt: Date())
                cur.state = .awaitingConfirmation
            } else { cur.state = .draft }
            self.save(cur)
        })
    }

    /// Whole-song beats and bar lines for the selection stage. Reuses a sibling clip's grid (same
    /// source file); otherwise detects it and, if another clip of the song has a confirmed tempo
    /// and bar line, lines the grid up with that.
    func detectSongGrid(_ itemId: UUID) {
        guard let item = item(itemId), item.songGrid == nil, !songGridRunning.contains(itemId) else { return }
        let siblings = items(of: item.songId).filter { $0.id != itemId && $0.source.fingerprint == item.source.fingerprint }
        if let g = siblings.compactMap(\.songGrid).first {
            var cur = item; cur.songGrid = g; save(cur); return
        }
        songGridRunning.insert(itemId)
        Task { [weak self] in
            guard let self else { return }
            defer { self.songGridRunning.remove(itemId) }
            do {
                var g = try await self.pipeline.detectSongGrid(item.source)
                if let ref = siblings.first(where: { $0.hasValidTiming }), let t = ref.timing {
                    let bar = t.barAnchorUs.map { (Double(ref.trimStartUs + $0)) / 1e6 }
                    g.calibrate(confirmedBpm: t.bpm, beatsPerBar: t.meter.numerator, barLineAt: bar)
                }
                guard var cur = self.item(itemId), cur.songGrid == nil else { return }
                cur.songGrid = g
                self.save(cur)
            } catch {
                self.songGridError[itemId] = error.localizedDescription
                self.dataVersion += 1
            }
        }
    }

    /// Bar-line adjustments (half-time, meter, shift); the selection itself is unchanged.
    func updateSongGrid(_ itemId: UUID, _ f: (inout SongGrid) -> Void) {
        guard var item = item(itemId), var g = item.songGrid else { return }
        f(&g)
        item.songGrid = g
        save(item)
    }

    func updateSelection(_ itemId: UUID, start: Int64, end: Int64) {
        guard var item = item(itemId), item.separation == nil else { return }
        guard start != item.trimStartUs || end != item.trimEndUs else { return }
        item.trimStartUs = max(0, start)
        item.trimEndUs = min(Int64(item.source.durationSec * 1_000_000), end)
        item.trimRevision += 1
        // A new range invalidates suggestions and confirmation.
        item.detection = nil
        item.timing = nil
        if item.state != .draft { item.state = .draft }
        save(item)
    }

    // MARK: Stage 2 – confirm & separate

    func confirmAndSeparate(_ itemId: UUID, timing: TimingConfirmation) {
        guard var item = item(itemId) else { return }
        item.timing = timing.anchoredOnBeat
        item.timingRevision += 1
        item.state = .separating
        save(item)
        startJob(.separate, item: item, revision: item.trimRevision, body: { [weak self] job, progress in
            guard let self else { return }
            let rec = try await self.pipeline.separate(item, jobDir: self.paths.jobDirectory(job.id), progress: progress)
            guard var cur = self.item(itemId), cur.trimRevision == rec.trimRevision else { return }
            cur.separation = rec
            cur.state = .awaitingStem
            self.save(cur)
        }, onError: { [weak self] error in
            guard let self, var cur = self.item(itemId) else { return }
            cur.state = .awaitingConfirmation
            self.save(cur)
            if !(error is CancellationError) { self.report(error) }
        })
    }

    /// Changing the grid after confirmation keeps audio and note times; derived analysis goes stale.
    func updateTiming(_ itemId: UUID, timing: TimingConfirmation) {
        guard var item = item(itemId) else { return }
        item.timing = timing.anchoredOnBeat
        item.timingRevision += 1
        save(item)
    }

    // MARK: Stage 3 – transcribe

    /// 重选分轨: back to choosing stems for this clip, its trimmed audio being still there. When
    /// the unselected stems were removed at the last confirmation, the clip is separated again
    /// first. Notes, tags and earlier MIDI and harmony revisions stay; transcribing makes new
    /// ones. An open harmony check belongs to the old MIDI and is dropped.
    func reselectStems(_ itemId: UUID) {
        guard var item = item(itemId) else { return }
        if playAlongItem == itemId { stopPlayAlong() }
        AudioEngine.shared.stopAll()
        discardDraft(itemId)
        for m in store.all(MidiRevision.self, owner: itemId) where m.status == .draft { try? store.delete(MidiRevision.self, id: m.id) }
        if let sep = item.separation, !sep.candidatesDeleted {
            item.state = .awaitingStem
            save(item)
        } else if let t = item.timing {
            confirmAndSeparate(itemId, timing: t)
        }
    }

    /// Whether 重选分轨 has to separate again (the other stems were removed).
    func reselectNeedsSeparation(_ item: AnalysisItem) -> Bool { item.separation?.candidatesDeleted ?? true }

    /// Leaves the stem choice opened by 重选分轨 and goes back to the confirmed result.
    func cancelReselect(_ itemId: UUID) {
        guard var item = item(itemId), item.confirmedMidiRevision != nil, latestHarmony(itemId) != nil || !item.isHarmonic else { return }
        AudioEngine.shared.stopAll()
        item.state = .ready
        save(item)
    }

    func transcribe(_ itemId: UUID, stem: StemKind) {
        transcribe(itemId, stems: item(itemId).map { $0.selectedStem == stem ? $0.selectedStems : [stem] } ?? [stem])
    }

    /// Transcribes one stem, or several harmony stems mixed into one track first.
    func transcribe(_ itemId: UUID, stems: [StemKind]) {
        guard var item = item(itemId), let first = stems.first, stems.allSatisfy({ item.separation?.stem($0) != nil }) else { return }
        let existing = store.all(MidiRevision.self, owner: itemId)
        let next = (existing.map(\.revision).max() ?? 0) + 1
        // Switching stems before confirmation discards the current draft.
        for m in existing where m.status == .draft { try? store.delete(MidiRevision.self, id: m.id) }
        item.selectedStem = first
        item.extraStems = stems.count > 1 ? Array(stems.dropFirst()) : nil
        item.state = .transcribing
        save(item)
        let stem = first
        startJob(.transcribe, item: item, revision: next, body: { [weak self] _, progress in
            guard let self else { return }
            var item = item
            if item.selectedStems.count > 1 || item.separation?.mix != nil {
                progress(StageProgress("合并所选分轨"))
                if let sep = try await self.pipeline.prepareStemMix(item) {
                    item.separation = sep
                    if var cur = self.item(itemId) { cur.separation = sep; self.save(cur) }
                }
            }
            let midi = try await self.pipeline.transcribe(item, stem: stem, revision: next, parent: nil, progress: progress)
            try self.store.save(midi)
            guard var cur = self.item(itemId) else { return }
            cur.state = .editingMidi
            self.save(cur)
            // One stop before harmony: the user picks the note bar 1 starts on (BarOneStage), then
            // harmony runs. Stems without harmony go straight on.
            if !cur.isHarmonic { self.confirmMidi(itemId) }
        }, onError: { [weak self] error in
            guard let self, var cur = self.item(itemId) else { return }
            cur.state = .awaitingStem
            self.save(cur)
            if !(error is CancellationError) { self.report(error) }
        })
    }

    func midiRevisions(_ itemId: UUID) -> [MidiRevision] { store.all(MidiRevision.self, owner: itemId).sorted { $0.revision < $1.revision } }

    /// The revision the editor works on: the open draft, else the confirmed one.
    func workingMidi(_ itemId: UUID) -> MidiRevision? {
        let revs = midiRevisions(itemId)
        return revs.last { $0.status == .draft } ?? revs.last { $0.status == .confirmed }
    }

    func saveDraft(_ itemId: UUID, notes: [MidiNote]) {
        guard let item = item(itemId) else { return }
        let revs = midiRevisions(itemId)
        if var draft = revs.last(where: { $0.status == .draft }) {
            draft.notes = notes
            try? store.save(draft)
        } else if let base = revs.last(where: { $0.status == .confirmed }) {
            var draft = MidiRevision(analysisId: itemId, revision: (revs.map(\.revision).max() ?? 0) + 1, status: .draft,
                                     parentRevision: base.revision, stem: base.stem, transcriber: base.transcriber, notes: notes)
            draft.midiFile = nil
            try? store.save(draft)
        }
        _ = item
        dataVersion += 1
    }

    func confirmMidi(_ itemId: UUID) {
        guard var item = item(itemId), var draft = midiRevisions(itemId).last(where: { $0.status == .draft }) else { return }
        draft.status = .confirmed
        draft.confirmedAt = Date()
        if let timing = item.timing {
            let url = paths.analysisAssets(itemId).appendingPathComponent("corrected-r\(draft.revision).mid")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ClipMidiExport.data(notes: draft.notes, timing: timing).write(to: url, options: .atomic)
            draft.midiFile = paths.relative(url)
            // Keep only the newest corrected.mid on disk; older notes stay in the database.
            for old in midiRevisions(itemId) where old.status == .confirmed {
                if let f = old.midiFile { paths.removeOwned(paths.url(relative: f)) }
            }
        }
        try? store.save(draft)
        item.confirmedMidiRevision = draft.revision
        if !(item.separation?.candidatesDeleted ?? true) { item = pipeline.deleteUnselectedStems(item) }
        if item.isHarmonic {
            item.state = .harmonizing
            save(item)
            runHarmony(itemId)
        } else {
            item.state = .ready
            save(item)
        }
    }

    // MARK: Stage 4 – harmony

    func latestHarmony(_ itemId: UUID) -> HarmonyRevision? {
        // SQLite reads aren't observable. Every view that reads the current harmony
        // must also depend on the invalidation signal used by reload/saveHarmony.
        let _ = dataVersion
        return store.all(HarmonyRevision.self, owner: itemId).max { $0.revision < $1.revision }
    }

    func confirmedMidi(_ item: AnalysisItem) -> MidiRevision? {
        guard let r = item.confirmedMidiRevision else { return nil }
        return midiRevisions(item.id).first { $0.revision == r }
    }

    func runHarmony(_ itemId: UUID) {
        guard let item = item(itemId), let midi = confirmedMidi(item), let timing = item.timing, item.isHarmonic else { return }
        let previous = latestHarmony(itemId)
        let next = (previous?.revision ?? 0) + 1
        startJob(.harmony, item: item, revision: midi.revision, body: { [weak self] _, progress in
            guard let self else { return }
            progress(StageProgress("分组和弦并命名"))
            let rev = await self.pipeline.analyzeHarmony(item, midi: midi, timing: timing, revision: next, previous: previous)
            try self.store.save(rev)
            guard var cur = self.item(itemId) else { return }
            cur.harmonyRevision = rev.revision
            cur.state = .ready
            self.save(cur)
            self.autoSkeleton(itemId)
        }, onError: { [weak self] error in
            guard let self, var cur = self.item(itemId) else { return }
            cur.state = .ready // MIDI stays usable even if harmony failed
            self.save(cur)
            if !(error is CancellationError) { self.report(error) }
        })
    }

    func saveHarmony(_ rev: HarmonyRevision) {
        try? store.save(rev)
        dataVersion += 1
    }

    /// Harmony is stale when built from an older MIDI or timing revision.
    func harmonyStale(_ item: AnalysisItem) -> [String] {
        guard let h = latestHarmony(item.id) else { return [] }
        var out = h.needsReview
        // An adopted model result isn't the grouping algorithm's output, so a newer algorithm says nothing about it.
        if h.params["algorithm"] != ChordGrouper.algorithm && h.params["algorithm"] != "agent" {
            out.append("和弦分组算法已更新（能识别拍子之间的快速经过和弦），可重新分析")
        }
        if let r = item.confirmedMidiRevision, h.midiRevision != r { out.append("音符已修改，和弦与级数是旧版本") }
        if h.timingRevision != item.timingRevision { out.append("速度/拍点/拍号已修改，和弦分组待核对") }
        if let t = item.timing, t.key != h.key { out.append("调性已修改，级数需重算") }
        if midiRevisions(item.id).contains(where: { $0.status == .draft }) { out.append("有未完成校对的 MIDI 草稿") }
        return out
    }

    // MARK: Stage 5 – skeleton

    var skeletonRunning: Set<UUID> = []

    func latestSkeleton(_ itemId: UUID) -> Skeleton? {
        store.all(Skeleton.self, owner: itemId).max { $0.createdAt < $1.createdAt }
    }

    func autoSkeleton(_ itemId: UUID) {
        let pid = settings.defaultProvider
        if providerStatus[pid]?.state == .connected { generateSkeleton(itemId) }
    }

    func generateSkeleton(_ itemId: UUID, providerId: String? = nil) {
        guard let item = item(itemId), let harmony = latestHarmony(itemId), !harmony.events.isEmpty else { return }
        let pid = providerId ?? settings.defaultProvider
        guard let provider = providers[pid] else { return }
        let model = settings.providerModels[pid]
        let effort = validEffort(pid, model: model, effort: settings.providerEfforts[pid])
        var sk = Skeleton(analysisId: itemId, harmonyRevision: harmony.revision, provider: pid, model: model ?? "默认")
        try? store.save(sk)
        skeletonRunning.insert(itemId)
        dataVersion += 1
        Task { [weak self] in
            guard let self else { return }
            await SkeletonJob.run(item: item, harmony: harmony, store: self.store, provider: provider, model: model, effort: effort, into: &sk)
            try? self.store.save(sk)
            self.skeletonRunning.remove(itemId)
            self.dataVersion += 1
        }
    }

    static func onePass(_ pattern: String) -> String? { SkeletonJob.onePass(pattern) }

    /// Applies a corrected key: re-derives degrees, then regenerates the explanation in the new key.
    func applyKey(_ itemId: UUID, _ key: KeySignature) {
        guard var item = item(itemId), var t = item.timing else { return }
        t.key = key
        item.timing = t
        save(item)
        recomputeDegrees(itemId)
        generateSkeleton(itemId)
    }

    // MARK: Notes

    func noteDocument(_ itemId: UUID) -> NoteDocument { store.fetch(NoteDocument.self, id: itemId) ?? NoteDocument(analysisId: itemId) }

    func saveNote(_ doc: NoteDocument) {
        var d = doc; d.revision += 1; d.updatedAt = Date()
        try? store.save(d)
    }

    // MARK: Collections

    func collections() -> [LearningCollection] { store.all(LearningCollection.self) }

    func addToCollection(_ item: CollectionItem, title: String) {
        var c = collections().first { $0.title == title } ?? LearningCollection(title: title)
        c.items.append(item)
        try? store.save(c)
        dataVersion += 1
    }

    // MARK: Playground

    func newPlayground() {
        let p = PlaygroundProject(title: "新作品", key: KeySignature(tonic: 0, tonicName: "C", mode: .major), bpm: 90, meter: .fourFour)
        try? store.save(p)
        reload()
        route = .playground(p.id)
    }

    func save(_ project: PlaygroundProject) {
        var p = project; p.updatedAt = Date(); p.revision += 1
        try? store.save(p)
        playgrounds = store.all(PlaygroundProject.self).sorted { $0.updatedAt > $1.updatedAt }
    }

    func deletePlayground(_ p: PlaygroundProject) {
        try? store.delete(PlaygroundProject.self, id: p.id)
        if route == .playground(p.id) { route = nil }
        reload()
    }

    // MARK: Storage

    func storageSummary() -> [(String, Int64)] {
        [("音频与 MIDI 资产", Pipeline.directorySize(paths.assets)), ("任务临时文件", Pipeline.directorySize(paths.jobs)),
         ("波形缓存", Pipeline.directorySize(paths.waveformCache)), ("封面", Pipeline.directorySize(paths.covers)),
         ("数据库", (try? FileManager.default.attributesOfItem(atPath: paths.database.path)[.size] as? Int64) ?? 0)]
    }

    func backupLibrary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Musicnote 备份 \(Date().formatted(.iso8601.year().month().day())).musicnote"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try store.backup(to: url.appendingPathComponent("library.sqlite"))
            for dir in ["assets", "covers"] {
                let src = paths.root.appendingPathComponent(dir)
                let dst = url.appendingPathComponent(dir)
                if FileManager.default.fileExists(atPath: src.path) { try FileManager.default.copyItem(at: src, to: dst) }
            }
            alert = AppAlert(title: "备份完成", message: url.path)
        } catch { report(error) }
    }
}

enum TagText {
    /// Display keeps the original; search compares a normalized value (4–5–3–6 == 4-5-3-6 == ４-５).
    static func normalize(_ s: String) -> String {
        var t = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        for dash in ["–", "—", "−", "→", "~", "_", "/", " "] { t = t.replacingOccurrences(of: dash, with: "-") }
        while t.contains("--") { t = t.replacingOccurrences(of: "--", with: "-") }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "- ")).lowercased()
    }
}

// MARK: - Autonomous analysis

extension AppModel {
    func latestAutoRun(_ itemId: UUID) -> AutoRun? {
        if let live = autoRuns[itemId] { return live }
        return store.all(AutoRun.self, owner: itemId).max { $0.startedAt < $1.startedAt }
    }

    var autoAnalysisProvider: CodexProvider {
        if let p = _autoProvider { return p }
        let p = CodexProvider(binary: settings.tools.codexBinary, sandboxDir: paths.chatSandbox, enableCodeMode: true)
        _autoProvider = p
        return p
    }

    /// Claude Code reaches the same toolbox through `workers/mcp_bridge.py`.
    var autoClaudeProvider: ClaudeAgentProvider {
        if let p = _autoClaude { return p }
        let t = settings.tools
        let p = ClaudeAgentProvider(binary: t.claudeBinary, sandboxDir: paths.chatSandbox, python: t.systemPython, bridgeScript: t.workers + "/mcp_bridge.py")
        _autoClaude = p
        return p
    }

    /// Lets the model analyse the selection with Musicnote's tools. Older harmony revisions,
    /// the user's MIDI, notes and tags are never modified.
    func startAutoAnalysis(_ itemId: UUID, provider pid: String = "codex") {
        guard autoTasks[itemId] == nil, let item = item(itemId) else { return }
        guard item.timing != nil else {
            alert = AppAlert(title: "还不能自主分析", message: "先确认速度与调性，这样才能按小节分析。"); return
        }
        let model = settings.providerModels[pid]
        let effort = validEffort(pid, model: model, effort: settings.providerEfforts[pid]) ?? "medium"
        let run = AutoRun(analysisId: itemId, trimRevision: item.trimRevision, provider: pid, model: model ?? "默认",
                          maxToolCalls: AutoAgent.defaultMaxToolCalls, maxSeconds: AutoAgent.defaultMaxSeconds)
        let box = AutoToolbox(store: store, paths: paths, tools: settings.tools, item: item, run: run)
        box.onUpdate = { [weak self] r in Task { @MainActor in self?.autoRuns[itemId] = r } }
        autoRuns[itemId] = run
        try? store.save(run)
        let provider: any AgentProvider = pid == "claude" ? autoClaudeProvider : autoAnalysisProvider
        let title = song(item.songId)?.title ?? ""
        autoTasks[itemId] = Task { [weak self] in
            await AutoAgent.run(toolbox: box, provider: provider, songTitle: title, model: model, effort: effort)
            guard let self else { return }
            self.autoRuns[itemId] = nil
            self.autoTasks[itemId] = nil
            self.reload()
            // A finished result goes straight into checking.
            if box.run.status == .succeeded { self.reviewRun(itemId, run: box.run) }
            if box.run.status == .failed { self.alert = AppAlert(title: "自主分析没有完成", message: box.run.error ?? box.run.finalMessage) }
        }
    }

    func cancelAutoAnalysis(_ itemId: UUID) { autoTasks[itemId]?.cancel() }

    /// Bar 1 and the beat phase start at a note the user picked; the tempo stays.
    func setBarOne(_ itemId: UUID, atUs us: Int64) {
        guard var item = item(itemId), var t = item.timing else { return }
        t.barAnchorUs = us
        t.beatOriginUs = us
        item.timing = t
        item.timingRevision += 1
        save(item)
    }

    /// After transcription: bar 1 picked (or kept), then harmony.
    func confirmBarOne(_ itemId: UUID, atUs us: Int64?) {
        if let us { setBarOne(itemId, atUs: us) }
        confirmMidi(itemId)
    }

    /// Later, from the notes page: a model harmony is re-read in the new grid, a program one regrouped.
    func changeBarOne(_ itemId: UUID, atUs us: Int64) {
        setBarOne(itemId, atUs: us)
        harmonyFollowsTiming(itemId)
    }

    private func harmonyFollowsTiming(_ itemId: UUID) {
        guard let item = item(itemId) else { return }
        if var h = latestHarmony(itemId), h.params["algorithm"] == "agent" {
            h.timingRevision = item.timingRevision
            h.params["barAnchorUs"] = String(item.timing?.barAnchorUs ?? 0)
            saveHarmony(h)
        } else if item.isHarmonic, confirmedMidi(item) != nil {
            runHarmony(itemId)
        }
    }

    /// Moves the bar lines by whole or half beats; note times stay. A half beat also moves the
    /// beat phase. An adopted model result only needs re-reading in the new grid; a program
    /// grouping depends on the bar lines, so it is redone.
    func shiftBarLine(_ itemId: UUID, beats: Double) {
        guard var item = item(itemId), var t = item.timing else { return }
        let g = t.grid
        let barUs = g.beatUs * g.meter.quarterBeatsPerBar
        let current = Double(t.barAnchorUs ?? latestHarmony(itemId)?.barAnchorUs ?? t.beatOriginUs)
        var a = current + beats * g.beatUs
        while a < 0 { a += barUs }
        while a >= barUs { a -= barUs }
        t.barAnchorUs = Int64(a.rounded())
        if beats != beats.rounded() { t.beatOriginUs = Int64(a.rounded()) }
        item.timing = t
        item.timingRevision += 1
        save(item)
        if var h = latestHarmony(itemId), h.params["algorithm"] == "agent" {
            h.timingRevision = item.timingRevision
            h.params["barAnchorUs"] = String(t.barAnchorUs ?? 0)
            saveHarmony(h)
        } else if item.isHarmonic, confirmedMidi(item) != nil {
            runHarmony(itemId)
        }
    }

    /// The bar-line check on what the clip has: Logic evidence if a model run made it, and the MIDI.
    func barLineCheck(_ item: AnalysisItem) -> (BarLineCheck.Result, BeatGrid)? {
        guard var g = item.timing?.grid, let midi = confirmedMidi(item) else { return nil }
        if g.barAnchorUs == nil { g.barAnchorUs = latestHarmony(item.id)?.barAnchorUs }
        let logic = store.all(ChordEvidence.self, owner: item.id).filter { $0.trimRevision == item.trimRevision }
        let lg = (logic.last { $0.source == "original" } ?? logic.last)?.events ?? []
        let r = BarLineCheck.check(grid: g, durationUs: item.durationUs, logic: lg,
                                   notes: midi.notes.map { BarLineCheck.Note(pitch: $0.pitch, startUs: $0.startUs) })
        return (r, g)
    }

    /// Latest run that produced a result (a later failed or cancelled run doesn't hide it).
    func latestAutoResultRun(_ itemId: UUID) -> AutoRun? {
        store.all(AutoRun.self, owner: itemId).filter(\.submitted).max { $0.startedAt < $1.startedAt }
    }

    /// Plays the selection's audio (original mix or the selected stem) for [startUs, endUs).
    func audition(_ itemId: UUID, startUs: Int64, endUs: Int64, original: Bool) {
        guard let item = item(itemId) else { return }
        playAlongItem = nil
        let url: URL?
        var offset: Int64 = 0
        if original { url = Pipeline.resolve(item.source); offset = item.trimStartUs }
        else { url = item.transcriptionStem.map { paths.url(relative: $0.relativePath) } }
        guard let url else { alert = AppAlert(title: "无法试听", message: "找不到音频文件"); return }
        let key = url.path
        let buffer: AVAudioPCMBuffer
        if let b = auditionCache[key] { buffer = b } else {
            guard let b = try? AudioLoader.load(url) else { return }
            auditionCache = [key: b]
            buffer = b
        }
        let rate = buffer.format.sampleRate
        let e = AudioEngine.shared
        e.pause()
        e.configure(sampleRate: rate)
        e.setMidi([], enabled: false)
        e.setMetronome(MetronomeConfig())
        e.setTracks([AudioTrack(id: "audition", buffer: buffer)])
        e.setLength(Int64(buffer.frameLength))
        e.setLoop(nil)
        let f0 = Int64(Double(startUs + offset) / 1e6 * rate)
        e.play(from: f0)
        auditionStop?.cancel()
        auditionStop = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0.2, Double(endUs - startUs) / 1e6) * 1e9))
            if !Task.isCancelled { AudioEngine.shared.pause() }
        }
    }
}

struct LitChord: Equatable {
    var itemId: UUID
    var eventId: String
    var pitches: [Int]
    /// The chord lit before it, shown faintly so the voices' movement is visible.
    var previous: [Int]
}
