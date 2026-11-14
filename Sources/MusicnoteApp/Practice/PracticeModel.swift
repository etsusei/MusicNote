import AppKit
import Foundation
import MusicnoteCore
import MusicnotePractice
import UniformTypeIdentifiers

/// A take read from a Logic export, checked against the transcription and waiting for the
/// user to accept it (and to say whether a found shift should be undone).
struct PracticeImportPreview: Identifiable {
    let id = UUID()
    var fileName: String
    var take: LogicRoundTrip.Imported
    var report: AlignmentCheck.Report
    var durationUs: Int64
    /// The speed the file turned out to be at: half (the exported files) or full.
    var speed: Double

    var shiftUs: Int64? { if case .shifted(let us) = report.verdict { us } else { nil } }
}

/// Practice mode: the clip's trip to Logic and back, and the backing to play over.
extension AppModel {
    // MARK: Calibrated MIDI

    /// Every take brought back from Logic, oldest first.
    func practiceTakes(_ itemId: UUID) -> [PracticeMidi] {
        let _ = dataVersion
        return store.all(PracticeMidi.self, owner: itemId).sorted { $0.revision < $1.revision }
    }

    /// The take in use: the newest import.
    func practiceMidi(_ itemId: UUID) -> PracticeMidi? { practiceTakes(itemId).last }

    /// What practice plays and what goes to Logic: the calibrated take, else the transcription.
    func practiceNotes(_ item: AnalysisItem) -> [MidiNote]? {
        practiceMidi(item.id)?.notes ?? confirmedMidi(item)?.notes ?? workingMidi(item.id)?.notes
    }

    /// Reads a MIDI file exported from the clip's Logic project and checks that it still sits
    /// where the audio is. Nothing is saved until `savePracticeMidi`.
    func readPracticeMidi(_ itemId: UUID, url: URL) -> PracticeImportPreview? {
        guard let item = item(itemId), let timing = item.timing else { return nil }
        do {
            let file = try MidiFileReader.read(Data(contentsOf: url))
            let reference = confirmedMidi(item)?.notes ?? workingMidi(itemId)?.notes ?? []
            let read = LogicRoundTrip.read(file, timing: timing, reference: reference)
            guard !read.take.notes.isEmpty else {
                alert = AppAlert(title: "这个 MIDI 文件里没有音符", message: "请在 Logic 里选中钢琴的 MIDI 片段，再用「文件 › 导出 › 所选内容为 MIDI 文件」导出。")
                return nil
            }
            return PracticeImportPreview(fileName: url.lastPathComponent, take: read.take, report: read.report,
                                         durationUs: item.durationUs, speed: read.speed)
        } catch {
            alert = AppAlert(title: "读不了这个 MIDI 文件", message: error.localizedDescription)
            return nil
        }
    }

    /// Saves a read take as the newest calibrated MIDI; `undoShift` moves it back by the offset
    /// the check found. Earlier takes stay.
    @discardableResult
    func savePracticeMidi(_ itemId: UUID, _ preview: PracticeImportPreview, undoShift: Bool) -> PracticeMidi? {
        let fitted = LogicRoundTrip.fit(preview.take, shiftUs: undoShift ? (preview.shiftUs ?? 0) : 0, durationUs: preview.durationUs)
        guard !fitted.notes.isEmpty else {
            alert = AppAlert(title: "没有落在片段里的音符", message: "这个 MIDI 的音符都在片段的时间范围之外。")
            return nil
        }
        let next = (practiceTakes(itemId).map(\.revision).max() ?? 0) + 1
        let take = PracticeMidi(analysisId: itemId, revision: next, notes: fitted.notes, pedals: fitted.pedals, fileName: preview.fileName)
        do { try store.save(take) } catch { report(error); return nil }
        dataVersion += 1
        return take
    }

    func deletePracticeTake(_ take: PracticeMidi) {
        try? store.delete(PracticeMidi.self, id: take.id)
        dataVersion += 1
    }

    // MARK: To Logic

    /// Writes the clip, the selected stem and the MIDI into a new folder the user places, all
    /// three starting at the same moment and playing at half speed (see LogicRoundTrip).
    /// Returns the folder.
    func exportLogicBundle(_ itemId: UUID) async -> URL? {
        guard let item = item(itemId), let timing = item.timing, let notes = practiceNotes(item) else { return nil }
        guard let source = Pipeline.resolve(item.source) else {
            alert = AppAlert(title: "无法导出", message: "找不到原曲文件"); return nil
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        panel.message = "会在这里新建一个文件夹，放半速的原曲片段、分轨和 MIDI"
        guard panel.runModal() == .OK, let parent = panel.url else { return nil }
        let base = "\(song(item.songId)?.title ?? "Musicnote") - \(item.title)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var folder = parent.appendingPathComponent(base + "（Logic）", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(base)（Logic）\(n)", isDirectory: true); n += 1
        }
        let padUs = -LogicRoundTrip.startUs(timing)
        // The audio is first written at full speed beside the result, then slowed down.
        let scratch = folder.appendingPathComponent(".full-speed.wav")
        func slowed(_ name: String, _ write: (URL) async throws -> Void) async throws {
            try await write(scratch)
            let out = folder.appendingPathComponent(name)
            try await Task.detached(priority: .userInitiated) {
                try OfflineStretch.stretchFile(scratch, to: out, timeRatio: 1 / LogicRoundTrip.speed)
            }.value
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            try LogicRoundTrip.midiData(notes: notes, timing: timing, trackName: item.stemLabel.isEmpty ? "Musicnote" : item.stemLabel)
                .write(to: folder.appendingPathComponent("3 MIDI（半速）.mid"), options: .atomic)
            try await slowed("1 原曲（半速）.wav") { try await self.pipeline.exportWav(source, clipOf: item, padUs: padUs, to: $0) }
            if let stem = item.separation.flatMap({ $0.mix ?? item.selectedStem.flatMap($0.stem) }) {
                try await slowed("2 \(item.stemLabel.isEmpty ? "分轨" : item.stemLabel)（半速）.wav") {
                    try await self.pipeline.exportWav(self.paths.url(relative: stem.relativePath), padUs: padUs, to: $0)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            report(error); return nil
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        return folder
    }

    // MARK: Backing

    /// The clip without the selected stems, when it has been kept.
    func backingURL(_ item: AnalysisItem) -> URL? {
        guard let b = item.separation?.backing else { return nil }
        let url = paths.url(relative: b.relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// At MIDI confirmation the unselected stems go; first they are summed into the backing.
    /// Runs beside whatever comes next (harmony); if the clip has moved on to another stem
    /// choice or separation meanwhile, the stems are left for that.
    func keepBackingThenTrimStems(_ itemId: UUID) {
        guard let item = item(itemId), let sep = item.separation, !sep.candidatesDeleted else { return }
        let confirmed = item.confirmedMidiRevision
        let keep = Set(item.selectedStems)
        let others = sep.stems.filter { !keep.contains($0.kind) }
        let dir = sep.stems.first.map { paths.url(relative: $0.relativePath).deletingLastPathComponent() }
        Task { [weak self] in
            guard let self else { return }
            var backing: StemAsset?
            if let dir { backing = try? await self.pipeline.mixBacking(others, frames: sep.frames, into: dir) }
            guard var cur = self.item(itemId), cur.confirmedMidiRevision == confirmed,
                  ![.awaitingStem, .separating, .transcribing].contains(cur.state),
                  let now = cur.separation, now.createdAt == sep.createdAt, !now.candidatesDeleted else { return }
            if let backing { cur.separation?.backing = backing }
            cur = self.pipeline.deleteUnselectedStems(cur)
            self.save(cur)
        }
    }

    /// For a clip whose other stems are already gone: separates it again into the job's own
    /// folder (the kept stems, MIDI and harmony are not touched) and keeps only the backing.
    func rebuildBacking(_ itemId: UUID) {
        guard let item = item(itemId), item.hasValidTiming, let sep = item.separation, jobs[itemId] == nil,
              let dir = sep.stems.first.map({ paths.url(relative: $0.relativePath).deletingLastPathComponent() }) else { return }
        let keep = Set(item.selectedStems)
        startJob(.backing, item: item, revision: item.trimRevision, body: { [weak self] job, progress in
            guard let self else { return }
            let jobDir = self.paths.jobDirectory(job.id)
            let fresh = try await self.pipeline.separate(item, jobDir: jobDir, publishTo: jobDir.appendingPathComponent("stems", isDirectory: true), progress: progress)
            progress(StageProgress("合成伴奏"))
            let backing = try await self.pipeline.mixBacking(fresh.stems.filter { !keep.contains($0.kind) }, frames: fresh.frames, into: dir)
            guard var cur = self.item(itemId), cur.separation?.createdAt == sep.createdAt, let backing else { return }
            cur.separation?.backing = backing
            self.save(cur)
        }, onError: { [weak self] error in
            if !(error is CancellationError) { self?.report(error) }
        })
    }
}
