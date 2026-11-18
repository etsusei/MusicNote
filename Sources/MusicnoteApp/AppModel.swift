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
    case drums(UUID)
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
    var drumPatterns: [DrumPattern] = []
    var route: Route?
    /// The clip being practised: its page takes over the whole window.
    var practicing: UUID?
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
    var linkImportOpen = false
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
    var skeletonRunning: Set<UUID> = []

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

struct LitChord: Equatable {
    var itemId: UUID
    var eventId: String
    var pitches: [Int]
    /// The chord lit before it, shown faintly so the voices' movement is visible.
    var previous: [Int]
}
