import AVFoundation
import CryptoKit
import Foundation

public struct StageProgress: Sendable {
    public var stage: String
    public var completed: Int
    public var total: Int?
    public init(_ stage: String, _ completed: Int = 0, _ total: Int? = nil) { self.stage = stage; self.completed = completed; self.total = total }
}

public typealias ProgressHandler = @Sendable (StageProgress) -> Void

/// Runs each analysis stage. Every stage reads a fixed input revision, writes into
/// its own job directory, validates, and only then publishes into the asset tree.
public final class Pipeline: @unchecked Sendable {
    public let store: Store
    public let paths: AppPaths
    public var tools: ToolSettings

    public init(store: Store, paths: AppPaths, tools: ToolSettings) {
        self.store = store; self.paths = paths; self.tools = tools
    }

    // MARK: Source

    public static func inspectSource(url: URL) throws -> SourceRef {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw WorkerError(code: "SOURCE_MISSING", message: "无法读取音频：\(url.lastPathComponent)", retryable: false)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let rate = file.processingFormat.sampleRate
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return SourceRef(fileName: url.lastPathComponent, pathHint: url.path, bookmark: bookmark, bytes: bytes,
                         durationSec: Double(file.length) / rate, sampleRate: rate, frames: file.length,
                         fingerprint: fingerprint(url: url, bytes: bytes))
    }

    static func fingerprint(url: URL, bytes: Int64) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "size:\(bytes)" }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 1 << 20)) ?? Data()
        let digest = SHA256.hash(data: head)
        return "sha256-1m:" + digest.map { String(format: "%02x", $0) }.joined() + ":\(bytes)"
    }

    /// Resolves the external file; nil when it moved or vanished (UI offers 重新选择原曲).
    public static func resolve(_ source: SourceRef) -> URL? {
        if let bm = source.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bm, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let url = URL(fileURLWithPath: source.pathHint)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// True when a re-selected file is the same recording (size + head hash).
    public static func matches(_ source: SourceRef, url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        return fingerprint(url: url, bytes: bytes) == source.fingerprint
    }

    public struct Metadata: Sendable { public var title: String?; public var artist: String?; public var album: String?; public var artwork: Data? }

    public static func readMetadata(url: URL) async -> Metadata {
        let asset = AVURLAsset(url: url)
        var m = Metadata()
        guard let items = try? await asset.load(.commonMetadata) else { return m }
        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle: m.title = try? await item.load(.stringValue)
            case .commonKeyArtist: m.artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName: m.album = try? await item.load(.stringValue)
            case .commonKeyArtwork: m.artwork = try? await item.load(.dataValue)
            default: break
            }
        }
        return m
    }

    // MARK: Clip

    /// Decodes [trimStart, trimEnd) of the source to a 44.1 kHz stereo float WAV, by
    /// decoded sample position (never by MP3 byte offset).
    public func extractClip(_ item: AnalysisItem, to url: URL) async throws {
        guard let src = Self.resolve(item.source) else {
            throw WorkerError(code: "SOURCE_MISSING", message: "原曲文件找不到了，请重新选择原曲", retryable: false)
        }
        let sr = item.source.sampleRate
        let s = Int64((Double(item.trimStartUs) * sr / 1_000_000).rounded())
        let e = Int64((Double(item.trimEndUs) * sr / 1_000_000).rounded())
        guard e > s, s >= 0, e <= item.source.frames else {
            throw WorkerError(code: "INVALID_RANGE", message: "选区无效", retryable: false)
        }
        let w = WorkerProcess(tools.ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", src.path, "-map", "0:a:0",
                                             "-af", "atrim=start_sample=\(s):end_sample=\(e),asetpts=PTS-STARTPTS",
                                             "-ar", "44100", "-ac", "2", "-c:a", "pcm_f32le", url.path])
        let r = try await w.run()
        guard r.status == 0 else { throw WorkerError(code: "SOURCE_MISSING", message: "裁剪选区失败：\(r.stderr.suffix(300))") }
    }

    // MARK: Detection

    public func detect(_ item: AnalysisItem, jobDir: URL, progress: ProgressHandler) async throws -> Detection {
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        progress(StageProgress("裁剪选区"))
        let clip = jobDir.appendingPathComponent("clip.wav")
        try await extractClip(item, to: clip)
        try Task.checkCancellation()
        progress(StageProgress("Essentia 检测 BPM 与调性"))
        nonisolated(unsafe) var result: [String: Any]?
        let w = WorkerProcess(tools.essentiaPython, [tools.workers + "/essentia_worker.py", "detect", clip.path])
        let r = try await w.run { line in if let o = decodeJSONLine(line) { result = o } }
        guard let result else { throw WorkerError(code: "DETECTION_FAILED", message: "Essentia 无输出：\(r.stderr.suffix(300))") }
        if let err = result["error"] as? [String: Any] {
            throw WorkerError(code: "DETECTION_FAILED", message: err["message"] as? String ?? "检测失败")
        }
        let raw = result["rawBpm"] as? Double
        var errors: [String] = []
        if let e = result["rhythmError"] as? String { errors.append("节奏：" + e) }
        if let e = result["keyError"] as? String { errors.append("调性：" + e) }
        return Detection(
            trimRevision: item.trimRevision, rawBpm: raw, roundedBpm: raw.flatMap(Tempo.roundToHalf),
            ticksSec: result["ticks"] as? [Double] ?? [], confidence: result["confidence"] as? Double,
            estimates: result["estimates"] as? [Double] ?? [], rawKey: result["key"] as? String,
            rawScale: result["scale"] as? String, keyStrength: result["strength"] as? Double,
            params: ["rhythm": "RhythmExtractor2013/multifeature", "key": "KeyExtractor", "analysisRate": "44100 mono",
                     "bpmRange": "40-208"],
            version: result["version"] as? String ?? "", errors: errors, detectedAt: Date())
    }

    // MARK: Separation

    public func separate(_ item: AnalysisItem, jobDir: URL, progress: @escaping ProgressHandler) async throws -> SeparationRecord {
        guard item.hasValidTiming else {
            throw WorkerError(code: "TEMPO_KEY_UNCONFIRMED", message: "需要先确认速度与调性", retryable: false)
        }
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let clip = jobDir.appendingPathComponent("clip.wav")
        if !FileManager.default.fileExists(atPath: clip.path) {
            progress(StageProgress("裁剪选区"))
            try await extractClip(item, to: clip)
        }
        let wavDir = jobDir.appendingPathComponent("wav"), mp3Dir = jobDir.appendingPathComponent("mp3")
        for d in [wavDir, mp3Dir] { paths.removeOwned(d) }
        progress(StageProgress("Logic 模型拆轨", 0, nil))
        nonisolated(unsafe) var failure: WorkerError?
        nonisolated(unsafe) var logicVersion: String?
        let sep = WorkerProcess(tools.separatorBinary, ["--input", clip.path, "--output-dir", wavDir.path])
        let r = try await sep.run { line in
            guard let o = decodeJSONLine(line), let ev = o["event"] as? String else { return }
            switch ev {
            case "started": logicVersion = o["logicVersion"] as? String
            case "progress": progress(StageProgress("Logic 模型拆轨", o["completed"] as? Int ?? 0, o["total"] as? Int))
            case "error": failure = WorkerError(code: o["code"] as? String ?? "SEPARATION_FAILED", message: o["message"] as? String ?? "拆轨失败")
            default: break
            }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        guard r.status == 0 else { throw WorkerError(code: "SEPARATION_FAILED", message: "拆轨失败：\(r.stderr.suffix(300))") }

        progress(StageProgress("编码 192 kbps MP3"))
        nonisolated(unsafe) var manifest: [String: Any]?
        let enc = WorkerProcess(tools.systemPython, [tools.workers + "/encode_stems.py", "--input-dir", wavDir.path,
                                                     "--output-dir", mp3Dir.path, "--ffmpeg", tools.ffmpeg, "--ffprobe", tools.ffprobe])
        _ = try await enc.run { line in if let o = decodeJSONLine(line) { manifest = o } }
        try Task.checkCancellation()
        guard let manifest else { throw WorkerError(code: "ENCODE_FAILED", message: "MP3 编码无输出") }
        if let err = manifest["error"] as? [String: Any] {
            throw WorkerError(code: "ENCODE_FAILED", message: err["message"] as? String ?? "MP3 编码失败")
        }
        // WAVs were only needed for encoding.
        paths.removeOwned(wavDir)

        // Publish: move validated MP3s into the asset tree.
        let dest = paths.analysisAssets(item.id).appendingPathComponent("stems-r\(item.trimRevision)", isDirectory: true)
        paths.removeOwned(dest)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: mp3Dir, to: dest)
        var stems: [StemAsset] = []
        for s in manifest["stems"] as? [[String: Any]] ?? [] {
            guard let name = s["stem"] as? String, let kind = StemKind(rawValue: name), let file = s["file"] as? String else { continue }
            stems.append(StemAsset(kind: kind, relativePath: paths.relative(dest.appendingPathComponent(file)),
                                   bytes: (s["bytes"] as? NSNumber)?.int64Value ?? 0,
                                   decodedFrames: (s["decodedFrames"] as? NSNumber)?.int64Value ?? 0,
                                   peakDbfs: s["peakDbfs"] as? Double,
                                   level: StemLevel(rawValue: s["level"] as? String ?? "normal") ?? .normal))
        }
        guard stems.count == 6 else { throw WorkerError(code: "ENCODE_FAILED", message: "分轨不完整") }
        return SeparationRecord(trimRevision: item.trimRevision, stems: stems,
                                sharedGainDb: manifest["sharedGainDb"] as? Double ?? 0,
                                encoder: manifest["encoder"] as? String ?? "", logicVersion: logicVersion,
                                frames: (manifest["frames"] as? NSNumber)?.int64Value ?? 0, createdAt: Date(),
                                candidatesDeleted: false)
    }

    /// Removes the five unselected stems once MIDI is confirmed.
    public func deleteUnselectedStems(_ item: AnalysisItem) -> AnalysisItem {
        var item = item
        guard var sep = item.separation, let keep = item.selectedStem else { return item }
        for s in sep.stems where s.kind != keep { paths.removeOwned(paths.url(relative: s.relativePath)) }
        sep.stems = sep.stems.filter { $0.kind == keep }
        sep.candidatesDeleted = true
        item.separation = sep
        return item
    }

    // MARK: Transcription

    public func transcribe(_ item: AnalysisItem, stem: StemKind, revision: Int, parent: Int?,
                           progress: @escaping ProgressHandler) async throws -> MidiRevision {
        guard let asset = item.separation?.stem(stem) else {
            throw WorkerError(code: "TRANSCRIPTION_FAILED", message: "所选分轨已不存在", retryable: false)
        }
        let path = paths.url(relative: asset.relativePath).path
        progress(StageProgress("加载 MuScriptor \(tools.muscriptorModel)"))
        nonisolated(unsafe) var notes: [MidiNote] = []
        nonisolated(unsafe) var failure: WorkerError?
        nonisolated(unsafe) var seconds = 0.0
        let w = WorkerProcess(tools.muscriptorPython, [tools.workers + "/muscriptor_worker.py", path, "--stem", stem.rawValue,
                                                      "--model", tools.muscriptorModel, "--device", tools.muscriptorDevice])
        w.environment = ProcessInfo.processInfo.environment.merging(["PYTORCH_ENABLE_MPS_FALLBACK": "1"]) { $1 }
        let r = try await w.run { line in
            guard let o = decodeJSONLine(line), let ev = o["event"] as? String else { return }
            switch ev {
            case "progress": progress(StageProgress("MuScriptor 转录", o["completed"] as? Int ?? 0, o["total"] as? Int))
            case "note":
                guard let p = o["pitch"] as? Int, (0...127).contains(p),
                      let s = (o["startUs"] as? NSNumber)?.int64Value, let e = (o["endUs"] as? NSNumber)?.int64Value else { return }
                notes.append(MidiNote(pitch: p, startUs: s, endUs: max(e, s + 1000), instrument: o["instrument"] as? String ?? "",
                                      transcribedIndex: o["index"] as? Int))
            case "done": seconds = o["seconds"] as? Double ?? 0
            case "error": failure = WorkerError(code: o["code"] as? String ?? "TRANSCRIPTION_FAILED", message: o["message"] as? String ?? "转录失败")
            default: break
            }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        guard r.status == 0 else { throw WorkerError(code: "TRANSCRIPTION_FAILED", message: "转录失败：\(r.stderr.suffix(400))") }
        notes.sort { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }
        return MidiRevision(analysisId: item.id, revision: revision, status: .draft, parentRevision: parent, stem: stem,
                            transcriber: ["tool": "MuScriptor", "version": "0.2.2a1", "model": tools.muscriptorModel,
                                          "device": tools.muscriptorDevice, "stem": stem.rawValue,
                                          "inputSha": Self.fingerprint(url: URL(fileURLWithPath: path), bytes: asset.bytes),
                                          "seconds": String(format: "%.1f", seconds), "velocity": "default 100"],
                            notes: notes)
    }

    // MARK: Harmony

    public struct NamingResult: Sendable { public var raw: String?; public var symbol: String? }

    /// Names pitch sets with Musicpy. Missing or failing Musicpy just yields no names.
    public func nameWithMusicpy(_ sets: [(id: String, pitches: [Int])], key: KeySignature?) async -> ([String: NamingResult], String) {
        let payload: [String: Any] = ["items": sets.map { ["id": $0.id, "pitches": $0.pitches] }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return ([:], "") }
        nonisolated(unsafe) var response: [String: Any]?
        let w = WorkerProcess(tools.musicpyPython, [tools.workers + "/musicpy_worker.py"])
        w.stdinData = data
        _ = try? await w.run { line in if let o = decodeJSONLine(line) { response = o } }
        var out: [String: NamingResult] = [:]
        for item in response?["items"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String else { continue }
            let bassPc = (item["bass"] as? String).flatMap(Pitch.parsePitchClass)
            let sym = (item["polychord"] as? Bool == true) ? nil :
                ChordSymbol.fromMusicpy(root: item["root"] as? String, type: item["type"] as? String,
                                        bassPitchClass: bassPc, omit: item["omit"] as? [String] ?? [], key: key)
            out[id] = NamingResult(raw: item["raw"] as? String, symbol: sym)
        }
        return (out, "musicpy " + (response?["version"] as? String ?? "unavailable"))
    }

    public func analyzeHarmony(_ item: AnalysisItem, midi: MidiRevision, timing: TimingConfirmation, revision: Int,
                               previous: HarmonyRevision?, params: ChordGrouper.Params = .init()) async -> HarmonyRevision {
        let grouper = ChordGrouper(params: params)
        let groups = grouper.group(notes: midi.notes, grid: timing.grid, durationUs: item.durationUs, key: timing.key)
        let sets = groups.enumerated().map { (id: String(format: "chord-%02d", $0.offset + 1), pitches: $0.element.namingPitches) }
        let (names, namer) = await nameWithMusicpy(sets, key: timing.key)
        var events: [ChordEvent] = []
        for (i, g) in groups.enumerated() {
            let id = sets[i].id
            var candidates: [ChordCandidate] = []
            if let n = names[id], let s = n.symbol { candidates.append(ChordCandidate(symbol: s, source: .musicpy, score: nil, raw: n.raw)) }
            for c in g.candidates where !candidates.contains(where: { $0.symbol == c.symbol }) { candidates.append(c) }
            let topTemplate = g.candidates.first
            let symbol: String?
            let source: NamingSource?
            if let s = names[id]?.symbol { symbol = s; source = .musicpy }
            else if let t = topTemplate, (t.score ?? 0) >= 0.6 { symbol = t.symbol; source = .template }
            else { symbol = nil; source = nil }
            var ev = ChordEvent(id: id, order: i, startUs: g.startUs, endUs: g.endUs, noteIds: g.noteIds, noteRoles: g.roles,
                                texture: g.texture, excludedNoteIds: [], namingPitches: g.namingPitches, candidates: candidates,
                                symbol: symbol, namingSource: source, manualOverride: false, degree: nil, bassPitch: g.bassPitch)
            ev.degree = symbol.flatMap { Degrees.label(symbol: $0, key: timing.key) }
            events.append(ev)
        }
        var rev = HarmonyRevision(analysisId: item.id, revision: revision, midiRevision: midi.revision,
                                  timingRevision: item.timingRevision, key: timing.key, events: events,
                                  params: params.dictionary, namerVersion: namer)
        // Carry manual overrides across regrouping when the event clearly survives; otherwise list for review.
        if let previous {
            for old in previous.events where old.manualOverride {
                if let idx = rev.events.firstIndex(where: { overlapRatio($0, old) >= 0.8 }) {
                    rev.events[idx].symbol = old.symbol
                    rev.events[idx].manualOverride = true
                    rev.events[idx].namingSource = .user
                    rev.events[idx].excludedNoteIds = old.excludedNoteIds.filter { rev.events[idx].noteIds.contains($0) }
                    rev.events[idx].degree = old.symbol.flatMap { Degrees.label(symbol: $0, key: timing.key) }
                } else {
                    rev.needsReview.append("待核对覆盖：\(formatTime(us: old.startUs)) 原人工命名 \(old.symbol ?? "未确定")")
                }
            }
        }
        return rev
    }

    func overlapRatio(_ a: ChordEvent, _ b: ChordEvent) -> Double {
        let inter = max(0, min(a.endUs, b.endUs) - max(a.startUs, b.startUs))
        let union = max(a.endUs, b.endUs) - min(a.startUs, b.startUs)
        return union > 0 ? Double(inter) / Double(union) : 0
    }

    /// Re-names one event after the user excluded notes or moved its edges.
    public func renameEvent(_ event: ChordEvent, notes: [MidiNote], key: KeySignature) async -> ChordEvent {
        var ev = event
        let members = notes.filter { ev.noteIds.contains($0.id) && !ev.excludedNoteIds.contains($0.id) }
        var lowest: [Int: Int] = [:]
        for n in members { lowest[Pitch.pc(n.pitch)] = min(lowest[Pitch.pc(n.pitch)] ?? n.pitch, n.pitch) }
        ev.namingPitches = lowest.values.sorted()
        var profile = [Double](repeating: 0, count: 12)
        for n in members { profile[Pitch.pc(n.pitch)] += Double(min(n.endUs, ev.endUs) - max(n.startUs, ev.startUs)) }
        let bassPc = members.min { $0.pitch < $1.pitch }.map { Pitch.pc($0.pitch) }
        let fits = TemplateMatcher.best(profile: profile, bassPc: bassPc, limit: 4)
        let (names, _) = await nameWithMusicpy([(id: ev.id, pitches: ev.namingPitches)], key: key)
        var candidates: [ChordCandidate] = []
        if let s = names[ev.id]?.symbol { candidates.append(ChordCandidate(symbol: s, source: .musicpy, score: nil, raw: names[ev.id]?.raw)) }
        for f in fits {
            let s = ChordSymbol.make(root: f.root, suffix: f.quality.suffix, bass: bassPc, key: key)
            if !candidates.contains(where: { $0.symbol == s }) { candidates.append(ChordCandidate(symbol: s, source: .template, score: f.score, raw: nil)) }
        }
        ev.candidates = candidates
        if !ev.manualOverride {
            ev.symbol = candidates.first?.symbol
            ev.namingSource = candidates.first?.source
            ev.degree = ev.symbol.flatMap { Degrees.label(symbol: $0, key: key) }
        }
        return ev
    }

    // MARK: Recovery

    /// Marks running jobs interrupted and removes job directories nothing refers to.
    public func recoverOnLaunch() -> [Job] {
        var interrupted: [Job] = []
        let jobs = store.all(Job.self)
        for var j in jobs where j.status == .running || j.status == .queued {
            j.status = .interrupted
            try? store.save(j)
            interrupted.append(j)
        }
        let known = Set(jobs.filter { $0.status == .failed || $0.status == .interrupted || $0.status == .running }.map { $0.id.uuidString })
        if let dirs = try? FileManager.default.contentsOfDirectory(at: paths.jobs, includingPropertiesForKeys: nil) {
            for d in dirs where !known.contains(d.lastPathComponent) { paths.removeOwned(d) }
        }
        return interrupted
    }

    /// Bytes used under a directory, for the storage page.
    public static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
