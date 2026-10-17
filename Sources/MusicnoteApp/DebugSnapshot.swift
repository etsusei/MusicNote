import AppKit
import Foundation
import MusicnoteCore

/// Development aid, inert unless MUSICNOTE_SNAPSHOT_DIR is set: visits the routes in
/// MUSICNOTE_ROUTES ("empty,settings,song:<uuid>,analysis:<uuid>[@tab],playground:<uuid>"),
/// renders the window to PNG for each, then quits. Lets the UI be checked without
/// screen-recording permission.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if DebugFlow.runIfRequested(model) { return }
        guard let dir = env["MUSICNOTE_SNAPSHOT_DIR"] else { return }
        let routes = (env["MUSICNOTE_ROUTES"] ?? "empty").split(separator: ",").map(String.init)
        let theme = env["MUSICNOTE_THEME"]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let theme { model.settings.theme = theme; model.applyTheme() }
            for (i, r) in routes.enumerated() {
                apply(r, model)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%02d-%@.png", i, r.replacingOccurrences(of: ":", with: "_").prefix(40) as CVarArg)))
            }
            NSApp.terminate(nil)
        }
    }

    static func apply(_ r: String, _ model: AppModel) {
        let parts = r.split(separator: "@")
        let route = String(parts[0])
        if parts.count > 1 { UserDefaults.standard.set(Int(parts[1]) ?? 0, forKey: "readyTab") }
        let kv = route.split(separator: ":", maxSplits: 1).map(String.init)
        switch kv[0] {
        case "settings": model.route = .settings
        case "bookmarks": model.route = .bookmarks
        case "song": model.route = UUID(uuidString: kv[1]).map { .song($0) }
        case "analysis": model.route = UUID(uuidString: kv[1]).map { .analysis($0) }
        case "playground": model.route = UUID(uuidString: kv[1]).map { .playground($0) }
        case "firstsong": model.route = model.songs.first.map { .song($0.id) }
        case "firstitem": model.route = model.songs.first.flatMap { model.items(of: $0.id).first }.map { .analysis($0.id) }
        case "firstplayground": model.route = model.playgrounds.first.map { .playground($0.id) }
        default: model.route = nil
        }
    }

    static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let view = window.contentView else { return }
        if let y = ProcessInfo.processInfo.environment["MUSICNOTE_SCROLLY"].flatMap(Double.init) {
            func deepest(_ v: NSView) -> NSScrollView? {
                for sv in v.subviews { if let f = deepest(sv) { return f } }
                return (v as? NSScrollView).flatMap { ($0.documentView?.bounds.height ?? 0) > 1500 ? $0 : nil }
            }
            if let sv = deepest(view), let doc = sv.documentView {
                doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? y : max(0, doc.bounds.height - sv.contentSize.height - y)))
                view.layoutSubtreeIfNeeded()
            }
        } else if ProcessInfo.processInfo.environment["MUSICNOTE_SCROLLTOP"] != nil {
            func visit(_ v: NSView) {
                if let sv = v as? NSScrollView, let doc = sv.documentView {
                    doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? 0 : max(0, doc.bounds.height - sv.contentSize.height)))
                }
                v.subviews.forEach(visit)
            }
            visit(view)
            view.layoutSubtreeIfNeeded()
        }
        let fr = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        try? fr.write(to: url.deletingPathExtension().appendingPathExtension("responder.txt"), atomically: true, encoding: .utf8)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// MUSICNOTE_FLOW_AUDIO=<file> (with MUSICNOTE_SNAPSHOT_DIR) drives the real AppModel
/// through every stage on a 20 s selection and writes flow.txt with checks.
@MainActor
enum DebugFlow {
    static func runIfRequested(_ model: AppModel) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let audio = env["MUSICNOTE_FLOW_AUDIO"], let dir = env["MUSICNOTE_SNAPSHOT_DIR"] else { return false }
        let start = Double(env["MUSICNOTE_FLOW_START"] ?? "75") ?? 75
        Task { @MainActor in
            var log: [String] = []
            @MainActor func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: dir + "/flow.txt", atomically: true, encoding: .utf8) }
            @MainActor func wait(_ what: String, timeout: Double = 300, _ cond: () -> Bool) async -> Bool {
                let t0 = Date()
                while !cond() {
                    if Date().timeIntervalSince(t0) > timeout { note("TIMEOUT waiting for \(what)"); return false }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                note(String(format: "ok  %@ (%.1fs)", what, Date().timeIntervalSince(t0)))
                return true
            }
            @MainActor func shot(_ name: String) async {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                DebugSnapshot.snapshot(to: URL(fileURLWithPath: dir + "/flow-\(name).png"))
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await model.createSong(from: URL(fileURLWithPath: audio))
            guard let song = model.songs.last, let first = model.items(of: song.id).first else { note("FAIL create"); NSApp.terminate(nil); return }
            let id = first.id
            model.updateSelection(id, start: Int64(start * 1e6), end: Int64((start + 20) * 1e6))
            note("song \(song.title) item \(id)")
            await shot("1-selection")
            model.analyze(id)
            guard await wait("detection", { model.item(id)?.state == .awaitingConfirmation }) else { NSApp.terminate(nil); return }
            let det = model.item(id)!.detection!
            note("bpm \(det.rawBpm ?? -1) → \(det.roundedBpm ?? -1), key \(det.rawKey ?? "?") \(det.rawScale ?? "?")")
            await shot("2-confirm")
            let pc = Pitch.parsePitchClass(det.rawKey ?? "C") ?? 0
            let timing = TimingConfirmation(trimRevision: model.item(id)!.trimRevision, bpm: det.roundedBpm ?? 120,
                                            beatOriginUs: Int64((det.ticksSec.first ?? 0) * 1e6), meter: .fourFour, meterConfirmed: true,
                                            barAnchorUs: Int64((det.ticksSec.first ?? 0) * 1e6),
                                            key: KeySignature(tonic: pc, tonicName: Pitch.name(pc: pc, flats: false), mode: det.rawScale == "minor" ? .minor : .major))
            model.confirmAndSeparate(id, timing: timing)
            guard await wait("separation", { model.item(id)?.state == .awaitingStem }) else { NSApp.terminate(nil); return }
            note("stems \(model.item(id)!.separation!.stems.map { "\($0.kind.rawValue):\($0.level.rawValue)" })")
            await shot("3-stems")
            model.transcribe(id, stem: .piano)
            // No proofreading stop: transcription is confirmed and harmony starts on its own.
            guard await wait("harmony", { model.item(id)?.state == .ready && model.jobs[id] == nil }) else { NSApp.terminate(nil); return }
            let item = model.item(id)!
            let h = model.latestHarmony(id)
            note("confirmed midi r\(item.confirmedMidiRevision ?? -1), notes \(model.confirmedMidi(item)?.notes.count ?? -1)")
            note("candidates deleted \(item.separation!.candidatesDeleted), stems left \(item.separation!.stems.map(\.kind.rawValue))")
            let assetDir = model.paths.analysisAssets(id)
            let files = (FileManager.default.enumerator(atPath: assetDir.path)?.allObjects as? [String]) ?? []
            note("asset files \(files.sorted())")
            note("harmony \(h?.events.map { $0.symbol ?? "?" }.joined(separator: " ") ?? "none")")
            note("stale \(model.harmonyStale(item))")
            note("job dirs left \((try? FileManager.default.contentsOfDirectory(atPath: model.paths.jobs.path)) ?? [])")
            // Skeleton (auto-started if the default provider is connected).
            if model.latestSkeleton(id) == nil { model.generateSkeleton(id) }
            _ = await wait("skeleton", timeout: 400, { !model.skeletonRunning.contains(id) && model.latestSkeleton(id) != nil })
            if let sk = model.latestSkeleton(id) { note("skeleton \(sk.status.rawValue) backbone \(sk.backboneEventIds) unstructured \(sk.unstructured) err \(sk.error ?? "")") }
            UserDefaults.standard.set(0, forKey: "readyTab")
            model.route = .analysis(id)
            await shot("5-ready")
            // Chat with an @analysis mention.
            model.chat.newConversation()
            model.chat.addMention(MentionOption(kind: .analysis, objectId: id, title: "\(song.title) · \(item.title)", subtitle: ""))
            model.chat.draft = "用两三句话说说这段进行里最值得练的一个和弦连接，并引用事件 ID。"
            model.chat.send()
            _ = await wait("chat", timeout: 300, { !model.chat.sending && model.chat.messages.count >= 2 })
            if let a = model.chat.messages.last { note("chat \(a.status.rawValue): \(a.content.prefix(160))") }
            note("mentions \(model.chat.messages.first?.mentions.map { "\($0.kind.rawValue) \($0.revisions)" } ?? [])")
            await shot("6-chat")
            note("DONE")
            NSApp.terminate(nil)
        }
        return true
    }
}
