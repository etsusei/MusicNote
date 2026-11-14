import AppKit
import CoreMIDI
import Foundation
import MusicnoteCore
import MusicnotePractice

/// Development aid, inert unless MUSICNOTE_SNAPSHOT_DIR is set: visits the routes in
/// MUSICNOTE_ROUTES ("empty,settings,song:<uuid>,analysis:<uuid>[@tab],playground:<uuid>,drums:<uuid>,practice:<uuid>"),
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
            if env["MUSICNOTE_SNAPSHOT_WINDOW"] == "灵感进行" { InspirationWindow.shared.show(model) }
            if env["MUSICNOTE_HIDE_CHAT"] != nil { model.showRight = false }
            for (i, r) in routes.enumerated() {
                apply(r, model)
                if model.practicing != nil, env["MUSICNOTE_PRACTICE_DRIVE"] != nil { await DebugPractice.drive(dir: dir) }
                // MUSICNOTE_LIGHT=<n>: light chord n of the clip's harmony (chord n-1 as the shadow).
                if let n = env["MUSICNOTE_LIGHT"].flatMap(Int.init), case .analysis(let id)? = model.route,
                   let item = model.item(id), let h = model.latestHarmony(id), n >= 1, n < h.events.count {
                    let notes = model.confirmedMidi(item)?.notes ?? [], beat = item.timing?.grid.beatUs ?? 500_000
                    for k in [n - 1, n] {
                        if let p = HeardVoicing.pitches(h.events[k], notes: notes, beatUs: beat) { model.light(id, eventId: h.events[k].id, pitches: p) }
                    }
                }
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
        model.practicing = nil
        switch kv[0] {
        case "practice": model.practicing = UUID(uuidString: kv[1])
        case "settings": model.route = .settings
        case "bookmarks": model.route = .bookmarks
        case "inspirations": model.route = .inspirations
        case "song": model.route = UUID(uuidString: kv[1]).map { .song($0) }
        case "analysis": model.route = UUID(uuidString: kv[1]).map { .analysis($0) }
        case "playground": model.route = UUID(uuidString: kv[1]).map { .playground($0) }
        case "firstsong": model.route = model.songs.first.map { .song($0.id) }
        case "firstitem": model.route = model.songs.first.flatMap { model.items(of: $0.id).first }.map { .analysis($0.id) }
        case "firstplayground": model.route = model.playgrounds.first.map { .playground($0.id) }
        case "drums": model.route = UUID(uuidString: kv[1]).map { .drums($0) }
        case "firstdrums": model.route = model.drumPatterns.first.map { .drums($0.id) }
        default: model.route = nil
        }
    }

    static func snapshot(to url: URL) {
        // MUSICNOTE_SNAPSHOT_WINDOW=<title> captures that window (e.g. 灵感进行) instead of the main one.
        let title = ProcessInfo.processInfo.environment["MUSICNOTE_SNAPSHOT_WINDOW"]
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && (title == nil || $0.title == title) }),
              let view = window.contentView else { return }
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
        // MUSICNOTE_SNAPSHOT_FRAME: the whole window frame, title bar and its buttons included.
        let target = ProcessInfo.processInfo.environment["MUSICNOTE_SNAPSHOT_FRAME"] != nil ? (view.superview ?? view) : view
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        // Resolve dynamic colors under the window's appearance, not the process default.
        window.effectiveAppearance.performAsCurrentDrawingAppearance { target.cacheDisplay(in: target.bounds, to: rep) }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// MUSICNOTE_FLOW_LINK=<pasted text> (with MUSICNOTE_SNAPSHOT_DIR) imports an Instagram or YouTube link through
/// the real AppModel, adds a second clip, runs detection (no separation or transcription) and writes
/// flow.txt. MUSICNOTE_FLOW_AUDIO=<file> instead drives every stage on a 20 s selection.
@MainActor
enum DebugFlow {
    private static func runLink(_ text: String, _ model: AppModel, dir: String) {
        Task { @MainActor in
            var log: [String] = []
            @MainActor func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: dir + "/flow.txt", atomically: true, encoding: .utf8) }
            @MainActor func shot(_ name: String) async {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                DebugSnapshot.snapshot(to: URL(fileURLWithPath: dir + "/link-\(name).png"))
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await shot("0-empty")
            model.linkImportOpen = true
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let sheet = NSApp.windows.compactMap(\.attachedSheet).first, let view = sheet.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                sheet.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/link-1-sheet.png"))
                note("sheet shown")
            } else { note("FAIL sheet not shown") }
            model.linkImportOpen = false
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let link = Pipeline.mediaLink(in: text) else { note("FAIL not recognised: \(text)"); NSApp.terminate(nil); return }
            note("link \(link.site.display) \(link.url.absoluteString)")
            await model.createSong(fromLink: link)
            if let a = model.alert { note("alert \(a.title): \(a.message)"); model.alert = nil }
            guard let song = model.songs.last, let first = model.items(of: song.id).first else { note("FAIL create"); NSApp.terminate(nil); return }
            note("song \(song.title) / \(song.artist) cover=\(song.coverFile != nil)")
            note("source \(first.source.fileName) \(first.source.durationSec) s @ \(first.source.sampleRate) link=\(first.source.link ?? "nil") path=\(first.source.pathHint)")
            await shot("2-selection")
            model.addAnalysis(to: song, like: first)
            let clips = model.items(of: song.id)
            note("clips \(clips.map(\.title)) sameSource=\(Set(clips.map(\.source.fingerprint)).count == 1)")
            model.analyze(first.id)
            let t0 = Date()
            while model.item(first.id)?.state == .detecting, Date().timeIntervalSince(t0) < 180 { try? await Task.sleep(nanoseconds: 300_000_000) }
            let det = model.item(first.id)?.detection
            note("state \(model.item(first.id)?.state.display ?? "?") bpm \(det?.roundedBpm ?? -1) key \(det?.rawKey ?? "?") \(det?.rawScale ?? "?")")
            if let a = model.alert { note("alert \(a.title): \(a.message)") }
            model.route = .analysis(first.id)
            await shot("3-confirm")
            NSApp.terminate(nil)
        }
    }

    static func runIfRequested(_ model: AppModel) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let text = env["MUSICNOTE_FLOW_LINK"], let dir = env["MUSICNOTE_SNAPSHOT_DIR"] { runLink(text, model, dir: dir); return true }
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
            // One stop: bar 1 is confirmed (kept as is here), then harmony runs.
            guard await wait("transcription", { model.item(id)?.state == .editingMidi }) else { NSApp.terminate(nil); return }
            model.confirmBarOne(id, atUs: nil)
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

/// MUSICNOTE_PRACTICE_DRIVE (with a `practice:<uuid>` route and MUSICNOTE_SNAPSHOT_DIR) plays the
/// practice page for real, with the output muted: it checks that the position moves at the
/// speed set, that a speed change takes, that the loop holds the position and that the keys
/// work, saves pictures along the way and writes practice.txt.
@MainActor
enum DebugPractice {
    static func drive(dir: String) async {
        var log: [String] = []
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(toFile: dir + "/practice.txt", atomically: true, encoding: .utf8) }
        func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        // A paused stage redraws only when asked; ask before each picture so it shows the position just set.
        func shot(_ name: String) async {
            PracticeSessionModel.current?.refreshStage()
            try? await Task.sleep(nanoseconds: 150_000_000)
            DebugSnapshot.snapshot(to: URL(fileURLWithPath: dir + "/practice-\(name).png"))
        }
        func key(_ chars: String, code: UInt16) {
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) { NSApp.sendEvent(e) }
            }
        }
        let e = AudioEngine.shared
        e.outputVolume = 0
        defer { e.outputVolume = 1; UserDefaults.standard.set("amber", forKey: "practicePalette") }
        await wait(1)
        guard let s = PracticeSessionModel.current else { note("FAIL no practice session"); return }
        let t0 = Date()
        while s.loading, Date().timeIntervalSince(t0) < 30 { await wait(0.2) }
        note("clip \(Double(s.durationUs) / 1e6) s, \(s.timeline.notes.count) notes, \(s.pedals.count) pedal spans, \(s.bars.lines.count) bar lines, calibrated \(s.calibrated)")
        note("backings loaded: \(PracticeBacking.allCases.filter { s.available.contains($0) }.map(\.rawValue)) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s; chosen \(s.settings.backing.rawValue)")
        if s.loopOn { s.toggleLoop() }
        s.setRate(1)
        // MUSICNOTE_PRACTICE_DRIVE=speed: only whether the speed control works, in a few seconds.
        if ProcessInfo.processInfo.environment["MUSICNOTE_PRACTICE_DRIVE"] == "speed" {
            func speed(_ seconds: Double) async -> Double {
                let a = s.positionUs, t = Date()
                await wait(seconds)
                return Double(s.positionUs - a) / 1e6 / Date().timeIntervalSince(t)
            }
            s.seek(toUs: s.durationUs / 8)
            s.togglePlay()
            await wait(0.5)
            let full = await speed(1.5)
            s.setRate(0.5)
            await wait(0.5)
            let half = await speed(1.5)
            let st = e.speedState()
            note("time stretching \(st.stretching ? "on" : "OFF") \(st.stretching ? "OK" : "FAIL")")
            note("speed 1.0: played at \(String(format: "%.2f", full)) × \(abs(full - 1) < 0.05 ? "OK" : "FAIL")")
            note("speed set to 0.5 while playing: played at \(String(format: "%.2f", half)) × \(abs(half - 0.5) < 0.05 ? "OK" : "FAIL")")
            s.togglePlay()
            s.setRate(1)
            note("done")
            return
        }
        s.setMidi(on: true)

        // Paused at a quarter of the way in.
        let quarter = s.durationUs / 4
        s.seek(toUs: quarter)
        await wait(0.6)
        note("seek while paused: asked \(quarter), at \(s.positionUs), drawn at \(s.visualUs())")
        await shot("1-paused")

        // Playing at full speed, then at half.
        func measure(_ seconds: Double) async -> Double {
            let a = s.positionUs, t = Date()
            await wait(seconds)
            return Double(s.positionUs - a) / 1e6 / Date().timeIntervalSince(t)
        }
        s.togglePlay()
        await wait(0.5)
        let drawnBefore = PracticeStageView.framesDrawn
        let full = await measure(2)
        // Nothing changes any view state during these two seconds: the stage has to redraw by itself.
        let fps = Double(PracticeStageView.framesDrawn - drawnBefore) / 2
        note("stage redrew \(String(format: "%.0f", fps)) times a second while playing, with no other change on the page \(fps >= 20 ? "OK" : "FAIL: the stage is not redrawing by itself")")
        note("speed 1.0: position moved at \(String(format: "%.3f", full)) × real time \(abs(full - 1) < 0.03 ? "OK" : "FAIL")")
        let lead = Double(s.visualUs() - s.positionUs) / 1000
        note("drawn position against the engine's: \(String(format: "%+.1f", lead)) ms (negative: the picture waits for the sound to come out)")
        s.setRate(0.5)
        await wait(0.6)
        let half = await measure(2)
        note("speed 0.5 set while playing: position moved at \(String(format: "%.3f", half)) × real time \(abs(half - 0.5) < 0.03 ? "OK" : "FAIL")")
        await shot("2-playing-half-speed")

        // Keys: − and = step the speed, L the loop, [ and ] its ends, space play/pause.
        key("-", code: 27); await wait(0.2)
        note("key −: speed \(s.settings.rate) \(abs(s.settings.rate - 0.5) < 1e-9 ? "OK (already at the slowest)" : "FAIL")")
        key("=", code: 24); await wait(0.2)
        note("key =: speed \(s.settings.rate) \(abs(s.settings.rate - 0.55) < 1e-9 ? "OK" : "FAIL")")
        key("=", code: 24); key("=", code: 24); await wait(0.2)
        key("-", code: 27); await wait(0.2)
        note("keys = = −: speed \(s.settings.rate) \(abs(s.settings.rate - 0.6) < 1e-9 ? "OK" : "FAIL")")
        key("l", code: 37); await wait(0.3)
        note("key L: loop \(s.loopOn ? "on" : "off") \(s.loop.map { "\($0.lowerBound)–\($0.upperBound) (bars \(s.bars.label($0)))" } ?? "-") \(s.loopOn ? "OK" : "FAIL")")
        key(" ", code: 49); await wait(0.3)
        note("key space: \(e.isPlaying ? "playing FAIL" : "paused OK")")
        key(" ", code: 49); await wait(0.3)
        note("key space again: \(e.isPlaying ? "playing OK" : "paused FAIL")")

        // The loop holds the position: one bar of lead-in before A, never past B.
        s.setRate(1)
        if let range = s.playRange, let loop = s.loop {
            var lowest = Int64.max, highest = Int64.min, wraps = 0, last = s.positionUs
            let span = Double(range.upperBound - range.lowerBound) / 1e6
            let t = Date()
            while Date().timeIntervalSince(t) < min(span * 1.6 + 1, 25) {
                await wait(0.05)
                let p = s.positionUs
                if p < last - 500_000 { wraps += 1 }
                last = p; lowest = min(lowest, p); highest = max(highest, p)
            }
            let inside = lowest >= range.lowerBound - 50_000 && highest <= range.upperBound + 50_000
            note("loop A–B \(loop.lowerBound)–\(loop.upperBound), played \(range.lowerBound)–\(range.upperBound): position stayed in \(lowest)–\(highest), wrapped \(wraps)× \(inside && wraps >= 1 ? "OK" : "FAIL")")
            await shot("3-looping")
            key("]", code: 30); await wait(0.3)
            note("key ]: loop now \(s.loop.map { "\($0.lowerBound)–\($0.upperBound)" } ?? "-")")
        } else { note("FAIL no loop to play") }

        // Real mouse drags, posted to the app as the system would: the speed slider dragged from
        // full speed to half over a second and a half, then the timeline dragged across four bars.
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let content = w.contentView {
            func mouse(_ type: NSEvent.EventType, _ p: CGPoint) {
                if let ev = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(ev, atStart: false)
                }
            }
            func sliders(_ v: NSView) -> [NSSlider] { (v as? NSSlider).map { [$0] } ?? v.subviews.flatMap(sliders) }
            if s.loopOn { s.toggleLoop() }
            s.setRate(1)
            s.seek(toUs: s.durationUs / 8)
            if !e.isPlaying { s.togglePlay() }
            await wait(0.8)
            let sf = PracticeTopBar.debugSpeedFrame
            note("speed slider at \(sf), AppKit sliders in the window: \(sliders(content).count)")
            if sf.width > 10 {
                let y = content.bounds.height - sf.midY, right = sf.maxX - 8, left = sf.minX + 8
                mouse(.leftMouseDown, CGPoint(x: right, y: y))
                await wait(0.1)
                var line: [String] = []
                var last = s.positionUs, lastT = Date()
                let frames = PracticeStageView.framesDrawn
                let dragTicks = TransportModel.ticks
                let dragBegan = Date()
                defer {
                    let perSecond = Double(TransportModel.ticks - dragTicks) / Date().timeIntervalSince(dragBegan)
                    note("during the speed drag the time display's timer ticked \(String(format: "%.0f", perSecond)) times a second \(perSecond >= 20 ? "OK" : "FAIL: it stands still while a mouse button is down")")
                }
                // 150 small moves, 10 ms apart, as a hand would drag; a reading every tenth of a second.
                for step in 1...150 {
                    mouse(.leftMouseDragged, CGPoint(x: right + (left - right) * CGFloat(step) / 150, y: y))
                    await wait(0.01)
                    if step % 10 == 0 {
                        let p = s.positionUs, t = Date()
                        line.append(String(format: "%.2f→%.2f", s.settings.rate, Double(p - last) / 1e6 / t.timeIntervalSince(lastT)))
                        last = p; lastT = t
                    }
                }
                let fps = Double(PracticeStageView.framesDrawn - frames) / Date().timeIntervalSince(lastT.addingTimeInterval(-0.1 * Double(line.count) + 0.1)).magnitude
                let endRate = s.settings.rate
                await wait(0.5)
                let held = await measure(0.5)
                mouse(.leftMouseUp, CGPoint(x: left, y: y))
                await wait(0.3)
                note("speed slider dragged 1.0 → 0.5, each 0.1 s as (setting→measured speed): \(line.joined(separator: " "))")
                note("  at the end of the drag: setting \(endRate), measured \(String(format: "%.2f", held)) with the button still down \(abs(endRate - 0.5) < 0.03 && abs(held - 0.5) < 0.05 ? "OK" : "FAIL"); stage redrew about \(String(format: "%.0f", fps)) times a second during the drag")
            } else { note("FAIL speed slider not found") }
            // The engine's own response to one jump in speed, read every 50 ms.
            s.setRate(1); await wait(1)
            s.setRate(0.5)
            var response: [String] = []
            var p0 = s.positionUs, t0 = Date()
            for _ in 1...12 {
                await wait(0.05)
                let p = s.positionUs, t = Date()
                response.append(String(format: "%.2f", Double(p - p0) / 1e6 / t.timeIntervalSince(t0)))
                p0 = p; t0 = t
            }
            note("one jump 1.0 → 0.5, speed every 50 ms after it: \(response.joined(separator: " "))")
            // How long a seek holds the main thread.
            let began = Date()
            for i in 0..<100 { s.seek(toUs: s.durationUs / 3 + Int64(i) * 10_000) }
            note("100 seeks took \(String(format: "%.1f", Date().timeIntervalSince(began) * 1000)) ms on the main thread")
            s.setRate(1)
            let f = PracticeTimeline.debugFrame
            if f.width > 10 {
                func point(_ us: Int64) -> CGPoint {
                    CGPoint(x: f.minX + CGFloat(Double(us) / Double(s.durationUs)) * f.width, y: content.bounds.height - (f.minY + 34))
                }
                let from = s.durationUs / 2, to = s.durationUs / 2 + Int64(s.bars.barUs * 2)
                mouse(.leftMouseDown, point(from))
                await wait(0.15)
                var line: [String] = []
                var frames = PracticeStageView.framesDrawn
                let dragBegan = Date()
                for step in 1...100 {
                    let target = from + (to - from) * Int64(step) / 100
                    mouse(.leftMouseDragged, point(target))
                    await wait(0.01)
                    if step % 10 == 0 { line.append(String(format: "%.2f/%.2f", Double(target) / 1e6, Double(s.positionUs) / 1e6)) }
                }
                let dragFps = Double(PracticeStageView.framesDrawn - frames) / Date().timeIntervalSince(dragBegan)
                note("timeline drag of 100 moves 10 ms apart took \(String(format: "%.2f", Date().timeIntervalSince(dragBegan))) s")
                // Held still at the end of the drag: playback should carry on from there.
                frames = PracticeStageView.framesDrawn
                let heldSpeed = await measure(1)
                let heldFps = Double(PracticeStageView.framesDrawn - frames)
                mouse(.leftMouseUp, point(to))
                await wait(0.3)
                note("timeline dragged, each 0.1 s as (mouse at/position, seconds): \(line.joined(separator: " "))")
                note("  stage redrew \(String(format: "%.0f", dragFps)) times a second while dragging; held still with the button down, playback ran at \(String(format: "%.2f", heldSpeed)) × and the stage redrew \(String(format: "%.0f", heldFps)) times a second \(abs(heldSpeed - 1) < 0.1 && heldFps >= 20 ? "OK" : "FAIL")")
            } else { note("FAIL timeline not found") }
        }

        // A keyboard: a virtual MIDI source stands in for the piano. A key the music asks for
        // is judged right, another wrong, and both are forgotten when released.
        var midiClient = MIDIClientRef(), virtual = MIDIEndpointRef()
        MIDIClientCreateWithBlock("Musicnote 测试键盘" as CFString, &midiClient, nil)
        MIDISourceCreateWithProtocol(midiClient, "测试键盘" as CFString, ._1_0, &virtual)
        func send(_ pitch: Int, down: Bool) {
            var list = MIDIEventList()
            let first = MIDIEventListInit(&list, ._1_0)
            let word: UInt32 = (down ? 0x2090_0000 : 0x2080_0000) | UInt32(pitch) << 8 | (down ? 100 : 0)
            _ = MIDIEventListAdd(&list, 1024, first, mach_absolute_time(), 1, [word])
            MIDIReceivedEventList(virtual, &list)
        }
        await wait(0.8)
        note("keyboard sources seen: \(s.keyboard.sources) \(s.keyboard.sources.contains("测试键盘") ? "OK" : "FAIL")")
        if e.isPlaying { s.togglePlay() }
        if s.loopOn { s.toggleLoop() }
        // A long note whose pitch is silent for the two seconds before it, so an early press has nothing to land on.
        if let target = s.timeline.notes.first(where: { n in
            n.startUs > s.durationUs / 3 && n.endUs - n.startUs > 300_000
                && !s.timeline.notes.contains { $0.pitch == n.pitch && $0.endUs > n.startUs - 2_000_000 && $0.startUs < n.startUs }
        }) {
            let unused = (40...90).first { p in !s.timeline.notes.contains { $0.pitch == p } } ?? 22
            s.seek(toUs: target.startUs + 50_000)
            await wait(0.4)
            send(target.pitch, down: true); send(unused, down: true)
            await wait(0.3)
            note("paused inside a note of pitch \(target.pitch): pressing it is \(s.judge.held[target.pitch].map { "\($0)" } ?? "not seen") \(s.judge.held[target.pitch] == .hit ? "OK" : "FAIL"); pressing \(unused) is \(s.judge.held[unused].map { "\($0)" } ?? "not seen") \(s.judge.held[unused] == .wrong ? "OK" : "FAIL")")
            await shot("4-keys-pressed")
            send(target.pitch, down: false); send(unused, down: false)
            await wait(0.3)
            note("released: \(s.judge.held.count) keys held \(s.judge.held.isEmpty ? "OK" : "FAIL")")
            // Playing: press the next long note as it arrives, and the same pitch half a second too early.
            s.seek(toUs: max(0, target.startUs - 1_500_000))
            s.togglePlay()
            await wait(0.3) // the display clock catches up with the seek at the next rendered buffer
            while s.visualUs() < target.startUs - 600_000, e.isPlaying { await wait(0.01) }
            send(target.pitch, down: true); await wait(0.1)
            let early = s.judge.held[target.pitch]
            send(target.pitch, down: false)
            while s.visualUs() < target.startUs, e.isPlaying { await wait(0.005) }
            send(target.pitch, down: true); await wait(0.1)
            let onTime = s.judge.held[target.pitch]
            send(target.pitch, down: false)
            note("playing: pitch \(target.pitch) pressed 0.6 s early is \(early.map { "\($0)" } ?? "not seen") \(early == .wrong ? "OK" : "FAIL"), pressed as it arrives is \(onTime.map { "\($0)" } ?? "not seen") \(onTime == .hit ? "OK" : "FAIL")")
        } else { note("FAIL no long note to press") }
        MIDIEndpointDispose(virtual); MIDIClientDispose(midiClient)
        await wait(0.6)
        note("keyboard unplugged: sources \(s.keyboard.sources) \(s.keyboard.sources.contains("测试键盘") ? "FAIL" : "OK")")
        if !e.isPlaying { s.togglePlay() }

        // The other palette.
        UserDefaults.standard.set("cool", forKey: "practicePalette")
        await wait(0.8)
        await shot("5-cool")
        s.togglePlay()
        if s.loopOn { s.toggleLoop() }
        s.setMidi(on: false)
        note("done")
    }
}
