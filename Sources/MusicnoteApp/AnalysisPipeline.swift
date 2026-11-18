import Foundation
import MusicnoteCore

/// A clip's way through the analysis: the background jobs, then detect, confirm and separate,
/// transcribe, harmony and skeleton, each stage's saved revisions.
extension AppModel {
    // MARK: Jobs

    func startJob(_ type: JobType, item: AnalysisItem, revision: Int,
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
        if item.isHarmonic {
            item.state = .harmonizing
            save(item)
            runHarmony(itemId)
        } else {
            item.state = .ready
            save(item)
        }
        // The unselected stems go now, summed into the practice backing first.
        keepBackingThenTrimStems(itemId)
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
}
