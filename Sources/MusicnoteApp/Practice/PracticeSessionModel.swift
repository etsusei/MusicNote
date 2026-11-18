import AVFoundation
import Foundation
import MusicnoteCore
import MusicnotePractice

/// One practice sitting with a clip: what is on the stage, the audio under it, and the
/// settings (speed, backing, loop) kept for the clip between sittings.
@MainActor @Observable
final class PracticeSessionModel {
    /// Everything on the engine runs at this rate; the original clip is resampled to it.
    static let sampleRate = 44_100.0
    /// The sitting on screen, for the keys and the debug driver.
    static weak var current: PracticeSessionModel?

    let item: AnalysisItem
    let title: String
    let subtitle: String
    let timeline: NoteTimeline
    let pedals: [PedalSpan]
    let bars: PracticeBars
    let bpm: Double
    /// The confirmed beats and key, for the metronome and for naming what is played.
    let grid: BeatGrid
    let key: KeySignature
    /// Whether the notes are the take calibrated in Logic (else the transcription).
    let calibrated: Bool

    private(set) var settings: PracticeSettings
    /// The backings whose audio is loaded and can be chosen.
    private(set) var available: Set<PracticeBacking> = [.off]
    private(set) var loading = true
    /// Bumped whenever something the stage draws changes while paused (a seek, a new loop).
    private(set) var redraw = 0

    /// The MIDI keyboard being played, if one is connected.
    let keyboard = MidiKeyboardInput()
    /// Keys held on it, each right or wrong as it went down.
    private(set) var judge = PracticeJudge()
    /// What the keys spelt when one last went down; `chordHeld` says whether they still are.
    private(set) var chord: HeldChord?
    private(set) var chordHeld = false
    /// Moves the picture and the judging later (positive) or earlier against the sound.
    @ObservationIgnored var offsetSeconds = 0.0

    /// Wait mode's account of which notes have been played.
    @ObservationIgnored private var gate: WaitGate
    @ObservationIgnored private var wrapsSeen = 0
    @ObservationIgnored private var waitTimer: Timer?
    /// Whether the music is standing still for a key right now.
    private(set) var waiting = false

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var tracks: [String: AudioTrack] = [:]
    @ObservationIgnored private var loader: Task<Void, Never>?

    init?(model: AppModel, itemId: UUID) {
        guard let item = model.item(itemId), let timing = item.timing, let notes = model.practiceNotes(item) else { return nil }
        self.model = model
        self.item = item
        let take = model.practiceMidi(itemId)
        calibrated = take != nil
        timeline = NoteTimeline(LogicRoundTrip.withoutOverlaps(notes))
        gate = WaitGate(timeline: timeline)
        pedals = take?.pedals ?? []
        bars = PracticeBars(timing: timing, durationUs: item.durationUs)
        bpm = timing.bpm
        grid = timing.anchoredOnBeat.grid
        key = timing.key
        let song = model.song(item.songId)
        title = song?.title ?? item.title
        subtitle = [song?.artist ?? "", item.title, "\(timing.key.tonicName) \(timing.key.mode == .minor ? "小调" : "大调")", "\(String(format: "%g", timing.bpm)) BPM"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        settings = model.store.fetch(PracticeSettings.self, id: itemId) ?? PracticeSettings(analysisId: itemId)
        settings.rate = min(max(settings.rate, PracticeSettings.rateRange.lowerBound), PracticeSettings.rateRange.upperBound)
        if let l = loop { let fixed = bars.loop(l.lowerBound, l.upperBound); settings.loopStartUs = fixed.lowerBound; settings.loopEndUs = fixed.upperBound }
    }

    // MARK: Units

    var durationUs: Int64 { item.durationUs }
    private func frame(_ us: Int64) -> Int64 { Int64((Double(us) * Self.sampleRate / 1_000_000).rounded()) }
    private func us(_ frame: Double) -> Int64 { Int64((frame / Self.sampleRate * 1_000_000).rounded()) }

    /// The position to draw at this instant, moved by `offsetSeconds` for a display that runs
    /// ahead of or behind the sound.
    func visualUs(offsetSeconds: Double = 0) -> Int64 { us(AudioEngine.shared.visualPosition(offsetSeconds: offsetSeconds)) }
    /// The position the engine is at (what the next buffer plays).
    var positionUs: Int64 { us(AudioEngine.shared.positionExact) }

    // MARK: Start and stop

    func start() {
        Self.current = self
        let e = AudioEngine.shared
        // Hold the engine first: pages still on their way out clear it as they go.
        e.hold(for: self)
        e.reset()
        e.configure(sampleRate: Self.sampleRate)
        e.setTracks([])
        e.setLength(frame(durationUs))
        e.setStretching(true)
        e.setRate(settings.rate)
        applyMidi()
        applyMetronome()
        applyLoop()
        e.seek(loopOn ? frame(playRange?.lowerBound ?? 0) : 0)
        loadTracks()
        keyboard.onKey = { [weak self] pitch, down, hostTime in self?.key(pitch, down: down, hostTime: hostTime) }
        keyboard.onSourcesChanged = { [weak self] in self?.restartWait() }
        keyboard.start()
        restartWait()
    }

    /// A key on the connected keyboard. It is judged against the music at the moment it was
    /// pressed (the event's own time), not when the event reached this thread.
    private func key(_ pitch: Int, down: Bool, hostTime: UInt64) {
        if down {
            syncWraps()
            let at = us(AudioEngine.shared.visualPosition(offsetSeconds: offsetSeconds, hostTime: hostTime))
            let owed = waitActive && gate.keyDown(pitch, atUs: at, rate: settings.rate)
            judge.keyDown(pitch, atUs: at, rate: settings.rate, in: timeline, accepted: owed)
            if owed { applyGate() }
        } else {
            judge.keyUp(pitch)
        }
        // Named as each key goes down; letting go one key at a time keeps the chord struck.
        if down { chord = HeldChord.describe(judge.held.keys, key: key) }
        chordHeld = !judge.held.isEmpty
        redraw += 1
    }

    func stop() {
        waitTimer?.invalidate(); waitTimer = nil
        keyboard.stop()
        loader?.cancel()
        persist()
        AudioEngine.shared.release(from: self)
        AudioEngine.shared.reset()
        if Self.current === self { Self.current = nil }
    }

    func persist() { try? model?.store.save(settings) }

    /// Asks the stage to draw again now (it draws by itself only while playing).
    func refreshStage() { redraw += 1 }

    /// Loads the three backings off the main thread, the chosen one first, and hands each to
    /// the engine as it arrives.
    private func loadTracks() {
        guard let model else { return }
        var sources: [(PracticeBacking, URL, Int64, Int64)] = []
        if let url = Pipeline.resolve(item.source) { sources.append((.original, url, item.trimStartUs, item.trimEndUs)) }
        if let stem = item.separation.flatMap({ $0.mix ?? item.selectedStem.flatMap($0.stem) }) {
            let url = model.paths.url(relative: stem.relativePath)
            if FileManager.default.fileExists(atPath: url.path) { sources.append((.stem, url, 0, durationUs)) }
        }
        if let url = model.backingURL(item) { sources.append((.backing, url, 0, durationUs)) }
        sources.sort { a, _ in a.0 == settings.backing }
        loader = Task { [weak self] in
            for (kind, url, start, end) in sources {
                if Task.isCancelled { return }
                let track = await Task.detached(priority: .userInitiated) { () -> AudioTrack? in
                    (try? AudioLoader.loadClip(url, startUs: start, endUs: end, sampleRate: Self.sampleRate)).map { AudioTrack(id: kind.rawValue, buffer: $0) }
                }.value
                guard let self, !Task.isCancelled else { return }
                if let track { self.add(track, kind) }
            }
            guard let self else { return }
            self.loading = false
            // The backing chosen last time may be gone (a re-separation): fall back to what there is.
            if !self.available.contains(self.settings.backing) {
                self.setBacking([.original, .stem, .backing].first { self.available.contains($0) } ?? .off)
            }
        }
    }

    private func add(_ track: AudioTrack, _ kind: PracticeBacking) {
        track.gain = settings.backingGain
        track.muted = kind != settings.backing
        tracks[kind.rawValue] = track
        available.insert(kind)
        let e = AudioEngine.shared
        e.setTracks(Array(tracks.values))
        e.setLength(frame(durationUs))
        e.setInstrumentVolume(settings.midiGain)
    }

    // MARK: Transport

    var isPlaying: Bool { AudioEngine.shared.isPlaying }

    func togglePlay() {
        let e = AudioEngine.shared
        if e.isPlaying { e.pause(); redraw += 1; return }
        // At the end of the clip, start over (the loop's lead-in when looping).
        if positionUs >= durationUs - 20_000 { e.seek(frame(playRange?.lowerBound ?? 0)); restartWait() }
        e.play()
    }

    func seek(toUs target: Int64) {
        AudioEngine.shared.seek(frame(min(max(0, target), durationUs)))
        restartWait()
        redraw += 1
    }

    /// Moves by whole bars from the bar line at or before the position.
    func seek(bars count: Int) {
        let now = positionUs
        let here = ([0] + bars.lines.map(\.us)).last { $0 <= now + 50_000 } ?? 0
        seek(toUs: here + Int64(Double(count) * bars.barUs))
    }

    // MARK: Speed

    func setRate(_ rate: Double, save: Bool = true) {
        settings.rate = min(max(rate, PracticeSettings.rateRange.lowerBound), PracticeSettings.rateRange.upperBound)
        AudioEngine.shared.setRate(settings.rate)
        applyGate()
        if save { persist() }
    }

    func stepRate(_ steps: Int) { setRate(PracticeSettings.steppedRate(settings.rate, by: steps)) }

    // MARK: Backing and the MIDI aloud

    func setBacking(_ kind: PracticeBacking) {
        guard available.contains(kind) else { return }
        settings.backing = kind
        for (id, _) in tracks { AudioEngine.shared.updateTrack(id, muted: id != kind.rawValue) }
        persist()
    }

    func setBackingGain(_ gain: Float, save: Bool = true) {
        settings.backingGain = max(0, min(1, gain))
        for (id, _) in tracks { AudioEngine.shared.updateTrack(id, gain: settings.backingGain) }
        if save { persist() }
    }

    func setMidi(on: Bool) {
        settings.midiOn = on
        applyMidi()
        persist()
    }

    func setMidiGain(_ gain: Float, save: Bool = true) {
        settings.midiGain = max(0, min(1, gain))
        AudioEngine.shared.setInstrumentVolume(settings.midiGain)
        if save { persist() }
    }

    // MARK: Metronome

    /// Clicks on the confirmed beats, the first of each bar higher. They are placed on the
    /// stretched clock, so they follow the speed as it changes and stop while waiting.
    func setMetronome(on: Bool) {
        settings.metronome = on
        applyMetronome()
        persist()
    }

    func setMetronomeGain(_ gain: Float, save: Bool = true) {
        settings.metronomeGain = max(0, min(1, gain))
        applyMetronome()
        if save { persist() }
    }

    private func applyMetronome() {
        var m = MetronomeConfig()
        m.enabled = settings.metronomeOn
        m.bpm = grid.bpm
        m.volume = settings.metronomeVolume
        m.originFrame = frame(grid.beatOriginUs)
        m.barAnchorFrame = frame(bars.anchorUs)
        m.beatsPerBar = grid.meter.quarterBeatsPerBar
        AudioEngine.shared.setMetronome(m)
    }

    private func applyMidi() {
        let notes = settings.midiOn ? timeline.notes.map {
            ScheduledNote(startFrame: frame($0.startUs), endFrame: frame($0.endUs), pitch: UInt8(clamping: $0.pitch), velocity: UInt8(clamping: max(1, $0.velocity)))
        } : []
        let e = AudioEngine.shared
        e.setMidi(notes, enabled: settings.midiOn)
        e.setLength(frame(durationUs))
        e.setInstrumentVolume(settings.midiGain)
    }

    // MARK: Loop

    /// The loop as set, A to B, whether or not it is on.
    var loop: Range<Int64>? {
        guard let a = settings.loopStartUs, let b = settings.loopEndUs, b > a else { return nil }
        return a..<b
    }

    var loopOn: Bool { settings.loopOn && loop != nil }
    var preroll: Bool { settings.preroll }

    /// What plays while looping: the loop, from a bar earlier with the lead-in.
    var playRange: Range<Int64>? { loopOn ? loop.map { bars.playRange($0, preroll: settings.preroll) } : nil }

    private func applyLoop() {
        AudioEngine.shared.setLoop(playRange.map { frame($0.lowerBound)..<frame($0.upperBound) })
        restartWait()
        redraw += 1
    }

    // MARK: Wait mode

    var waitOn: Bool { settings.waitOn }
    /// Waiting needs a keyboard to hear the keys from; without one the music just plays.
    var waitActive: Bool { settings.waitOn && !keyboard.sources.isEmpty }

    func toggleWait() {
        settings.wait = !settings.waitOn
        restartWait()
        persist()
    }

    /// Keys still owed at a position while waiting, for the stage to mark.
    func awaitedPitches(atUs us: Int64) -> Set<Int> { waitActive ? gate.awaited(atUs: us) : [] }

    /// Waiting starts afresh from where the music is: notes before it are not asked for.
    private func restartWait() {
        let e = AudioEngine.shared
        wrapsSeen = e.loopWraps
        // A note right at the position (a seek to its bar line) is still asked for.
        gate.restart(fromUs: positionUs - 20_000, loop: loopOn ? loop : nil, wrapToUs: playRange?.lowerBound ?? 0)
        applyGate()
        if waitActive, waitTimer == nil {
            // In the common modes, so it keeps going while a slider is dragged.
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.syncWraps()
                    let held = AudioEngine.shared.isHeldAtGate
                    if held != self.waiting { self.waiting = held }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            waitTimer = t
        } else if !waitActive {
            waitTimer?.invalidate(); waitTimer = nil
            if waiting { waiting = false }
        }
    }

    /// Tells the engine where to stop: a little past the start of the first note still owed,
    /// counted in what is heard (the engine runs ahead of the ears by the output's delay).
    private func applyGate() {
        let e = AudioEngine.shared
        guard waitActive else { e.setGate(nil, afterWrap: nil); return }
        let past = max(0, WaitGate.graceSeconds + e.outputLatencySeconds - offsetSeconds) * settings.rate
        let extra = Int64(past * Self.sampleRate)
        e.setGate(gate.awaitedUs.map { frame($0) + extra }, afterWrap: gate.awaitedAfterWrapUs.map { frame($0) + extra })
    }

    /// The loop came round since last looked: a new round, everything in it owed again.
    private func syncWraps() {
        let n = AudioEngine.shared.loopWraps
        guard n != wrapsSeen else { return }
        wrapsSeen = n
        gate.wrapped()
        applyGate()
    }

    func toggleLoop() {
        if loop == nil { setLoop(bars.defaultLoop(at: positionUs)); return }
        settings.loopOn.toggle()
        applyLoop()
        persist()
    }

    /// Sets the loop (snapped to bar lines) and turns it on.
    func setLoop(_ range: Range<Int64>, save: Bool = true) {
        let fixed = bars.loop(range.lowerBound, range.upperBound)
        let changed = fixed != loop || !settings.loopOn
        settings.loopStartUs = fixed.lowerBound; settings.loopEndUs = fixed.upperBound
        settings.loopOn = true
        if changed { applyLoop() }
        if save { persist() }
    }

    /// A at the bar line nearest the position; B stays, or moves four bars on when A passes it.
    func setLoopStart() {
        let a = bars.snap(positionUs)
        if let l = loop, a < l.upperBound { setLoop(a..<l.upperBound) } else { setLoop(a..<a + Int64(bars.barUs * 4)) }
    }

    /// B at the bar line nearest the position; A stays, or sits four bars before when B is not after it.
    func setLoopEnd() {
        let b = bars.snap(positionUs)
        if let l = loop, b > l.lowerBound { setLoop(l.lowerBound..<b) } else { setLoop(max(0, b - Int64(bars.barUs * 4))..<b) }
    }

    func togglePreroll() {
        settings.preroll.toggle()
        applyLoop()
        persist()
    }
}
