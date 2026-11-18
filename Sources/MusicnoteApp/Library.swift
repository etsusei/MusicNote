import AppKit
import Foundation
import MusicnoteCore
import UniformTypeIdentifiers

/// Songs and clips: importing audio (files, drops, links), replacing or relinking a clip's
/// source, saving and deleting.
extension AppModel {
    func reload() {
        songs = store.all(Song.self)
        var by: [UUID: [AnalysisItem]] = [:]
        for i in store.all(AnalysisItem.self) { by[i.songId, default: []].append(i) }
        itemsBySong = by
        playgrounds = store.all(PlaygroundProject.self).sorted { $0.updatedAt > $1.updatedAt }
        drumPatterns = store.all(DrumPattern.self).sorted { $0.updatedAt > $1.updatedAt }
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
            try saveNewSong(title: meta.title ?? url.deletingPathExtension().lastPathComponent, artist: meta.artist ?? "",
                            album: meta.album ?? "", artwork: meta.artwork, source: source)
            warnIfShort(source)
        } catch { report(error) }
    }

    /// A pasted Instagram or YouTube link as a new song. A short one is a reel or a Short, not a
    /// store preview, so there is no preview warning.
    func createSong(fromLink link: MediaLink) async {
        importStatus = "正在从 \(link.site.display) 下载音频…"
        defer { importStatus = nil }
        do {
            let media = try await pipeline.downloadLink(link)
            var source = try Pipeline.inspectSource(url: media.audio)
            source.fileName = "\(link.site.display) \(media.mediaId) 的音轨"
            source.link = link.url.absoluteString
            try saveNewSong(title: media.title, artist: media.artist, album: "", artwork: media.artwork, source: source)
        } catch { report(error) }
    }

    private func saveNewSong(title: String, artist: String, album: String, artwork: Data?, source: SourceRef) throws {
        var song = Song(title: title, artist: artist, album: album, sortIndex: (songs.map(\.sortIndex).max() ?? 0) + 1)
        if let artwork {
            let name = song.id.uuidString + ".img"
            try? artwork.write(to: paths.covers.appendingPathComponent(name))
            song.coverFile = name
        }
        try store.save(song)
        try saveNewClip(of: song, title: "片段 1", source: source)
    }

    private func saveNewClip(of song: Song, title: String, source: SourceRef) throws {
        let item = AnalysisItem(songId: song.id, title: title, source: source, trimStartUs: 0,
                                trimEndUs: Int64(min(source.durationSec, 30) * 1_000_000))
        try store.save(item)
        reload()
        route = .analysis(item.id)
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
            try saveNewClip(of: song, title: "片段 \(items(of: song.id).count + 1)", source: source)
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
}
