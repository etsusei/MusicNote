import AudioToolbox
import AVFoundation
import Foundation
import MusicnoteCore
import MusicnotePractice
import os

/// One playable audio source (whole song, clip or stem) held in memory.
final class AudioTrack: @unchecked Sendable {
    let id: String
    let buffer: AVAudioPCMBuffer
    var gain: Float = 1
    var muted = false
    var solo = false
    // Render-side smoothed gain for click-free mute/solo.
    fileprivate var current: Float = 1

    init(id: String, buffer: AVAudioPCMBuffer) { self.id = id; self.buffer = buffer }
    var frames: Int64 { Int64(buffer.frameLength) }
}

struct ScheduledNote: Hashable, Sendable {
    var startFrame: Int64
    var endFrame: Int64
    var pitch: UInt8
    var velocity: UInt8
    /// Played on the drum kit (GM percussion) instead of the melodic instrument.
    var drum = false
}

struct MetronomeConfig: Sendable {
    var enabled = false
    var bpm = 120.0
    var originFrame: Int64 = 0
    var volume: Float = 0.6
    /// Accent the downbeat only once a bar anchor is set.
    var barAnchorFrame: Int64?
    var beatsPerBar = 4.0
}

/// Shared transport. Audio tracks, the metronome and MIDI scheduling all read
/// the same render-thread sample position, so they stay locked together.
final class AudioEngine: @unchecked Sendable {
    static let shared = AudioEngine()

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private let drumSampler = AVAudioUnitSampler()
    private var sourceNode: AVAudioSourceNode?
    private(set) var sampleRate: Double = 44100

    private var lock = os_unfair_lock()
    // Render state (guarded by lock)
    private var tracks: [AudioTrack] = []
    private var events: [(frame: Int64, pitch: UInt8, velocity: UInt8, on: Bool, drum: Bool)] = []
    private var eventCursor = 0
    private var midiMuted = false
    private var midiSolo = false
    private var midiEnabled = false
    private var playing = false
    private var position: Int64 = 0
    private var loop: Range<Int64>?
    private var lengthFrames: Int64 = 0
    private var metronome = MetronomeConfig()
    private var clickRemaining = 0
    private var clickPhase = 0.0
    private var clickAccent = false
    private var activeNotes = Set<UInt8>()
    private var activeDrums = Set<UInt8>()
    private var needsAllOff = false

    private(set) var instrument: Instrument = .piano
    private var soundFont: URL?
    /// Practice playback: when set, the tracks go through the time stretcher and its clock
    /// drives the position, the MIDI events and the metronome (see `setStretching`).
    private var stretch: StretchPlayer?
    private var stretchRate = 1.0
    // Where playback stood at the end of the last rendered buffer, and when that buffer ends
    // on the host clock: lets a display work out the position at any instant between buffers.
    private var clockPosition = 0.0
    private var clockHostSeconds = 0.0
    private var clockFramesPerSecond = 0.0
    private static let hostTickSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()
    private var previewing = Set<UInt8>()

    private init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.attach(drumSampler)
        engine.connect(drumSampler, to: engine.mainMixerNode, format: nil)
        configure(sampleRate: 44100)
        loadDrumKit()
    }

    func start() {
        guard !engine.isRunning else { return }
        try? engine.start()
        outputLatency = engine.outputNode.presentationLatency
    }

    /// Time the sound takes from the engine to the listener's ears through the output device.
    private var outputLatency = 0.0

    /// Master level of everything the engine plays (1 by default).
    var outputVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Rebuilds the source node for a sample rate (song files may be 48 kHz; stems are 44.1 kHz).
    func configure(sampleRate rate: Double) {
        if sourceNode != nil, rate == sampleRate { return }
        if let n = sourceNode { engine.detach(n) }
        sampleRate = rate
        os_unfair_lock_lock(&lock)
        if stretch != nil { stretch = makeStretch(at: Double(position)) }
        os_unfair_lock_unlock(&lock)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let node = AVAudioSourceNode(format: format) { [unowned self] _, timestamp, frameCount, abl in
            self.render(frameCount: Int(frameCount), abl: abl, timestamp: timestamp)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        start()
    }

    // MARK: Instrument

    func loadSoundFont(_ url: URL) {
        soundFont = url
        setInstrument(instrument)
        loadDrumKit()
    }

    /// The GM percussion bank of the sound font, else of macOS's built-in bank.
    private func loadDrumKit() {
        let dls = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        let bank = UInt8(kAUSampler_DefaultPercussionBankMSB)
        if let sf = soundFont, FileManager.default.fileExists(atPath: sf.path),
           (try? drumSampler.loadSoundBankInstrument(at: sf, program: 0, bankMSB: bank, bankLSB: 0)) != nil { return }
        try? drumSampler.loadSoundBankInstrument(at: dls, program: 0, bankMSB: bank, bankLSB: 0)
    }

    func setInstrument(_ inst: Instrument) {
        instrument = inst
        if let sf = soundFont, FileManager.default.fileExists(atPath: sf.path) {
            try? sampler.loadSoundBankInstrument(at: sf, program: inst.program,
                                                 bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
        } else {
            // Fallback: macOS built-in General MIDI bank.
            let dls = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
            try? sampler.loadSoundBankInstrument(at: dls, program: inst.program,
                                                 bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
        }
        start()
    }

    // MARK: Session setup

    /// A new set of tracks starts with MIDI neither muted nor soloed: a solo left on in MIDI
    /// 校对 would otherwise silence the original everywhere else (play-along played only the
    /// chords). Views with their own mix (MidiStage) apply it after this.
    func setTracks(_ new: [AudioTrack]) {
        os_unfair_lock_lock(&lock)
        tracks = new
        lengthFrames = new.map(\.frames).max() ?? 0
        midiMuted = false
        midiSolo = false
        os_unfair_lock_unlock(&lock)
        sampler.volume = instrumentVolume
        drumSampler.volume = drumVolume
    }

    func updateTrack(_ id: String, muted: Bool? = nil, solo: Bool? = nil, gain: Float? = nil) {
        os_unfair_lock_lock(&lock)
        for t in tracks where t.id == id {
            if let muted { t.muted = muted }
            if let solo { t.solo = solo }
            if let gain { t.gain = gain }
        }
        os_unfair_lock_unlock(&lock)
    }

    /// `cut` silences what is sounding; editing a pattern while it plays passes false so a
    /// ringing cymbal isn't choked on every click.
    func setMidi(_ notes: [ScheduledNote], enabled: Bool, cut: Bool = true) {
        var ev: [(Int64, UInt8, UInt8, Bool, Bool)] = []
        for n in notes {
            ev.append((n.startFrame, n.pitch, n.velocity, true, n.drum))
            ev.append((max(n.endFrame, n.startFrame + 1), n.pitch, 0, false, n.drum))
        }
        // Offs before ons at the same frame so repeated notes retrigger.
        ev.sort { $0.0 != $1.0 ? $0.0 < $1.0 : (!$0.3 && $1.3) }
        os_unfair_lock_lock(&lock)
        events = ev.map { (frame: $0.0, pitch: $0.1, velocity: $0.2, on: $0.3, drum: $0.4) }
        midiEnabled = enabled
        eventCursor = cursorIndex(for: position)
        if cut { needsAllOff = true }
        lengthFrames = max(lengthFrames, notes.map(\.endFrame).max() ?? 0)
        os_unfair_lock_unlock(&lock)
    }

    func setLength(_ frames: Int64) {
        os_unfair_lock_lock(&lock); lengthFrames = frames; os_unfair_lock_unlock(&lock)
    }

    func setMidiMix(muted: Bool, solo: Bool) {
        os_unfair_lock_lock(&lock); midiMuted = muted; midiSolo = solo; os_unfair_lock_unlock(&lock)
        sampler.volume = midiAudible ? instrumentVolume : 0
        drumSampler.volume = midiAudible ? drumVolume : 0
    }

    private var drumVolume: Float = 1

    /// Level of the drum kit against the instrument and audio tracks.
    func setDrumVolume(_ v: Float) {
        drumVolume = max(0, min(1, v))
        drumSampler.volume = midiAudible ? drumVolume : 0
    }

    /// One kit hit now (clicking a lane name or a step).
    func tapDrum(_ note: Int, velocity: Int = 100) {
        start()
        let n = UInt8(clamping: note)
        drumSampler.startNote(n, withVelocity: UInt8(clamping: velocity), onChannel: 9)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.drumSampler.stopNote(n, onChannel: 9) }
    }

    private var midiAudible: Bool {
        let anySolo = midiSolo || tracks.contains { $0.solo }
        return !midiMuted && (!anySolo || midiSolo)
    }

    func setMetronome(_ m: MetronomeConfig) {
        os_unfair_lock_lock(&lock); metronome = m; os_unfair_lock_unlock(&lock)
    }

    func setLoop(_ range: Range<Int64>?) {
        os_unfair_lock_lock(&lock)
        loop = range
        if let s = stretch {
            s.setLoop(range)
            position = Int64(s.position); eventCursor = cursorIndex(for: position); needsAllOff = true
        }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Time stretching (practice)

    /// Turns time-stretched playback on or off. While on, the tracks play at `setRate`'s speed
    /// without changing pitch, and MIDI notes and the metronome follow at the same speed.
    func setStretching(_ on: Bool) {
        os_unfair_lock_lock(&lock)
        if on, stretch == nil { stretch = makeStretch(at: Double(position)) }
        if !on { stretch = nil }
        needsAllOff = true
        os_unfair_lock_unlock(&lock)
    }

    /// Playback speed while stretching: 1 is the original tempo. Takes effect while playing,
    /// gliding over a few hundredths of a second.
    func setRate(_ rate: Double) {
        os_unfair_lock_lock(&lock)
        stretchRate = min(max(rate, StretchPlayer.rateRange.lowerBound), StretchPlayer.rateRange.upperBound)
        stretch?.rate = stretchRate
        os_unfair_lock_unlock(&lock)
    }

    /// The position being heard right now, for drawing: the last rendered buffer's position
    /// carried forward (or back) to this instant at the speed it was playing, less the time
    /// the sound takes to leave the output device. `offsetSeconds` moves it later (positive)
    /// or earlier, for a display that runs ahead of or behind the sound.
    /// `hostTime` asks for the position heard at another instant (a key press), 0 for now.
    func visualPosition(offsetSeconds: Double = 0, hostTime: UInt64 = 0) -> Double {
        os_unfair_lock_lock(&lock)
        let pos = clockPosition, host = clockHostSeconds, speed = clockFramesPerSecond, range = loop
        os_unfair_lock_unlock(&lock)
        guard speed > 0 else { return pos }
        let now = Double(hostTime != 0 ? hostTime : mach_absolute_time()) * Self.hostTickSeconds
        var p = pos + (now - host - outputLatency + offsetSeconds) * speed
        if let range {
            if p >= Double(range.upperBound) { p -= Double(range.count) }
            p = max(p, Double(range.lowerBound))
        }
        return max(0, p)
    }

    /// Level of the built-in instrument that plays the MIDI (0–1).
    func setInstrumentVolume(_ v: Float) {
        instrumentVolume = max(0, min(1, v))
        sampler.volume = midiAudible ? instrumentVolume : 0
    }

    private var instrumentVolume: Float = 1

    /// The exact source position being heard (fractional while stretching).
    var positionExact: Double {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return stretch?.position ?? Double(position)
    }

    /// Call with the lock held.
    private func makeStretch(at frame: Double) -> StretchPlayer {
        let s = StretchPlayer(sampleRate: sampleRate)
        s.rate = stretchRate
        s.setLoop(loop)
        s.seek(to: frame)
        return s
    }

    // MARK: Transport

    func play(from frame: Int64? = nil) {
        start()
        os_unfair_lock_lock(&lock)
        if let frame { position = max(0, frame); eventCursor = cursorIndex(for: position); needsAllOff = true; stretch?.seek(to: Double(position)) }
        // A position left over from a longer source (e.g. the whole song) restarts at the top.
        if lengthFrames > 0, position >= lengthFrames {
            position = loop?.lowerBound ?? 0; eventCursor = cursorIndex(for: position); needsAllOff = true
            stretch?.seek(to: Double(position))
        }
        playing = true
        os_unfair_lock_unlock(&lock)
        // The output device may have changed since the engine started.
        outputLatency = engine.outputNode.presentationLatency
    }

    func pause() {
        os_unfair_lock_lock(&lock); playing = false; needsAllOff = true; os_unfair_lock_unlock(&lock)
        allNotesOff()
    }

    func seek(_ frame: Int64) {
        os_unfair_lock_lock(&lock)
        position = max(0, frame); eventCursor = cursorIndex(for: position); needsAllOff = true
        stretch?.seek(to: Double(position))
        // Paused, the picture shows the new place at once rather than after the next buffer
        // (the page redraws as it seeks, before the render thread has been round).
        if !playing { clockPosition = stretch?.position ?? Double(position); clockFramesPerSecond = 0 }
        os_unfair_lock_unlock(&lock)
    }

    var isPlaying: Bool { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return playing }
    var positionFrames: Int64 { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return position }

    /// A page that is going away clears the engine. While the practice page holds the engine
    /// this does nothing: the page being left says goodbye after the practice page has already
    /// set the engine up, and would otherwise switch its time stretching off again (the speed
    /// control then did nothing at all).
    func stopAll() {
        if holder != nil { return }
        reset()
    }

    /// Clears everything: tracks, MIDI, loop, metronome, time stretching.
    func reset() {
        pause()
        setStretching(false)
        setInstrumentVolume(1)
        setTracks([]); setMidi([], enabled: false); setLoop(nil)
        setGate(nil, afterWrap: nil)
        setMetronome(MetronomeConfig())
    }

    /// The practice sitting that holds the engine, if any (see `stopAll`).
    private weak var holder: AnyObject?
    func hold(for owner: AnyObject) { holder = owner }
    func release(from owner: AnyObject) { if holder === owner { holder = nil } }

    // MARK: Wait gate (practice)

    /// Wait mode: `frame` is a source position stretched playback may not pass; it stands
    /// there, silent and still playing, until the gate is moved on or cleared. `afterWrap`
    /// takes its place the moment the loop comes round, so the first note of the next round is
    /// waited for even before the main thread has noticed the wrap.
    func setGate(_ frame: Int64?, afterWrap: Int64?) {
        os_unfair_lock_lock(&lock); gate = frame; gateAfterWrap = afterWrap; os_unfair_lock_unlock(&lock)
    }

    /// Whether playback is standing at the gate right now.
    var isHeldAtGate: Bool { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return playing && gateHeld && gate != nil }
    /// How many times the loop has come round while stretching.
    var loopWraps: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return wrapCount }
    /// Metronome clicks sounded so far, for the debug driver to check that they follow the speed.
    var clicksPlayed: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return clickCount }
    private var clickCount = 0
    /// Seconds the sound takes to leave the output device.
    var outputLatencySeconds: Double { outputLatency }

    private var gate: Int64?
    private var gateAfterWrap: Int64?
    private var gateHeld = false
    private var wrapCount = 0
    /// Fade on each side of a stop at the gate, in output frames.
    private static let gateFade = 128

    /// Whether time-stretched playback is on.
    var isStretching: Bool { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return stretch != nil }

    private func cursorIndex(for frame: Int64) -> Int {
        var lo = 0, hi = events.count
        while lo < hi { let mid = (lo + hi) / 2; if events[mid].frame < frame { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    private func allNotesOff() {
        for ch: UInt8 in 0...1 { sampler.sendController(123, withValue: 0, onChannel: ch) }
        drumSampler.sendController(123, withValue: 0, onChannel: 9)
    }

    // MARK: Render (audio thread)

    private func render(frameCount: Int, abl: UnsafeMutablePointer<AudioBufferList>, timestamp: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let right = buffers.count > 1 ? buffers[1].mData!.assumingMemoryBound(to: Float.self) : left
        for i in 0..<frameCount { left[i] = 0; right[i] = 0 }
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }

        let schedule = sampler.auAudioUnit.scheduleMIDIEventBlock
        let drumSchedule = drumSampler.auAudioUnit.scheduleMIDIEventBlock
        func releaseAll(at i: Int) {
            for p in activeNotes { var b: [UInt8] = [0x80, p, 0]; schedule?(AUEventSampleTimeImmediate + AUEventSampleTime(i), 0, 3, &b) }
            for p in activeDrums { var b: [UInt8] = [0x89, p, 0]; drumSchedule?(AUEventSampleTimeImmediate + AUEventSampleTime(i), 0, 3, &b) }
            activeNotes.removeAll(); activeDrums.removeAll()
        }
        if needsAllOff {
            needsAllOff = false
            releaseAll(at: 0)
        }
        // The display clock: this buffer ends `frameCount` frames after its host time.
        let host = timestamp.pointee.mHostTime != 0 ? timestamp.pointee.mHostTime : mach_absolute_time()
        let bufferEnd = Double(host) * Self.hostTickSeconds + Double(frameCount) / sampleRate
        let before = stretch?.position ?? Double(position)
        defer {
            let after = stretch?.position ?? Double(position)
            clockPosition = after
            clockHostSeconds = bufferEnd
            // Across a loop wrap the difference is not the speed; keep the last one then.
            if !playing { clockFramesPerSecond = 0 } else if after >= before { clockFramesPerSecond = (after - before) / Double(frameCount) * sampleRate }
        }
        guard playing else { return }

        let anySolo = tracks.contains { $0.solo } || midiSolo
        let beatFrames = metronome.bpm > 0 ? sampleRate * 60 / metronome.bpm : 0
        if let stretch {
            renderStretched(stretch, frameCount: frameCount, left: left, right: right, anySolo: anySolo, beatFrames: beatFrames,
                            schedule: schedule, drumSchedule: drumSchedule)
            return
        }
        var pos = position
        for i in 0..<frameCount {
            if let loop, pos >= loop.upperBound || pos < loop.lowerBound {
                // Loop wrap: silence hanging notes (drums ring on), then continue from the loop start.
                for p in activeNotes { var b: [UInt8] = [0x80, p, 0]; schedule?(AUEventSampleTimeImmediate + AUEventSampleTime(i), 0, 3, &b) }
                activeNotes.removeAll()
                pos = loop.lowerBound
                eventCursor = cursorIndex(for: pos)
            } else if loop == nil, pos >= lengthFrames, lengthFrames > 0 {
                playing = false
                releaseAll(at: i)
                break
            }
            var l: Float = 0, r: Float = 0
            for t in tracks {
                let audible = !t.muted && (!anySolo || t.solo)
                let target: Float = audible ? t.gain : 0
                t.current += (target - t.current) * 0.003
                if t.current < 0.0001 && target == 0 { continue }
                if pos < t.frames, pos >= 0 {
                    let d = t.buffer.floatChannelData!
                    l += d[0][Int(pos)] * t.current
                    r += d[t.buffer.format.channelCount > 1 ? 1 : 0][Int(pos)] * t.current
                }
            }
            // Metronome click: phase from the absolute position, so loops stay in phase.
            if metronome.enabled, beatFrames > 0 {
                let b = Double(pos - metronome.originFrame) / beatFrames
                let pb = Double(pos - 1 - metronome.originFrame) / beatFrames
                if floor(b) > floor(pb) {
                    clickRemaining = Int(sampleRate * 0.03); clickPhase = 0; clickCount += 1
                    if let anchor = metronome.barAnchorFrame {
                        let beatsFromAnchor = (Double(pos - anchor) / beatFrames).rounded()
                        let m = beatsFromAnchor.truncatingRemainder(dividingBy: metronome.beatsPerBar)
                        clickAccent = abs(m) < 0.5
                    } else { clickAccent = false }
                }
                if clickRemaining > 0 {
                    let env = Float(clickRemaining) / Float(sampleRate * 0.03)
                    let freq = clickAccent ? 1760.0 : 1100.0
                    let s = Float(sin(clickPhase)) * env * env * metronome.volume * 0.5
                    clickPhase += 2 * .pi * freq / sampleRate
                    l += s; r += s; clickRemaining -= 1
                }
            }
            left[i] = l; right[i] = r
            // MIDI events landing on this frame.
            if midiEnabled {
                while eventCursor < events.count, events[eventCursor].frame <= pos {
                    let e = events[eventCursor]
                    if events[eventCursor].frame == pos {
                        let t = AUEventSampleTimeImmediate + AUEventSampleTime(i)
                        if e.drum {
                            var bytes: [UInt8] = e.on ? [0x99, e.pitch, e.velocity] : [0x89, e.pitch, 0]
                            drumSchedule?(t, 0, 3, &bytes)
                            if e.on { activeDrums.insert(e.pitch) } else { activeDrums.remove(e.pitch) }
                        } else {
                            var bytes: [UInt8] = e.on ? [0x90, e.pitch, e.velocity] : [0x80, e.pitch, 0]
                            schedule?(t, 0, 3, &bytes)
                            if e.on { activeNotes.insert(e.pitch) } else { activeNotes.remove(e.pitch) }
                        }
                    }
                    eventCursor += 1
                }
            }
            pos += 1
        }
        position = pos
    }

    /// The stretched path: the tracks are mixed at the source positions the stretcher asks for,
    /// and what it hands back is heard at the positions its clock gives. Metronome clicks and
    /// MIDI events are placed on those positions, so they stay with the audio at any speed
    /// (the click and the instrument themselves are not stretched).
    private func renderStretched(_ stretch: StretchPlayer, frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                                 anySolo: Bool, beatFrames: Double, schedule: AUScheduleMIDIEventBlock?, drumSchedule: AUScheduleMIDIEventBlock?) {
        // The wait gate: render only up to it. The stretcher keeps what it has taken in, so
        // playback goes on from the same place when the gate moves.
        let wasHeld = gateHeld
        var frameCount = frameCount
        if let g = gate {
            let toGate = (Double(g) - stretch.position) / max(stretch.heardRate, 0.05)
            let stop = toGate < (wasHeld ? Double(Self.gateFade) : 0.5) ? 0 : Int(min(toGate.rounded(.up), Double(frameCount)))
            gateHeld = stop < frameCount
            frameCount = stop
        } else { gateHeld = false }
        guard frameCount > 0 else { return }
        defer {
            if wasHeld {
                let n = min(frameCount, Self.gateFade)
                for i in 0..<n { let g = Float(i) / Float(n); left[i] *= g; right[i] *= g }
            }
            if gateHeld {
                let n = min(frameCount, Self.gateFade)
                for k in 0..<n { let i = frameCount - n + k; let g = Float(n - k) / Float(n); left[i] *= g; right[i] *= g }
            }
        }
        let rendered = stretch.render(frames: frameCount, left: left, right: right) { start, count, l, r in
            for i in 0..<count { l[i] = 0; r[i] = 0 }
            for t in tracks {
                let audible = !t.muted && (!anySolo || t.solo)
                let target: Float = audible ? t.gain : 0
                if t.current < 0.0001 && target == 0 { t.current = 0; continue }
                let d = t.buffer.floatChannelData!
                let c0 = d[0], c1 = d[t.buffer.format.channelCount > 1 ? 1 : 0]
                for i in 0..<count {
                    t.current += (target - t.current) * 0.003
                    let f = start + Int64(i)
                    if f >= 0, f < t.frames { l[i] += c0[Int(f)] * t.current; r[i] += c1[Int(f)] * t.current }
                }
            }
        }
        for (index, seg) in [rendered.first, rendered.second].enumerated() where seg.outCount > 0 && (index == 0 || rendered.wrapped) {
            if index == 1 {
                // Loop wrap: silence hanging notes (drums ring on), then continue from the loop start.
                for p in activeNotes { var b: [UInt8] = [0x80, p, 0]; schedule?(AUEventSampleTimeImmediate + AUEventSampleTime(seg.outOffset), 0, 3, &b) }
                activeNotes.removeAll()
                eventCursor = cursorIndex(for: Int64(seg.sourceStart))
            }
            let perFrame = (seg.sourceEnd - seg.sourceStart) / Double(seg.outCount)
            for k in 0..<seg.outCount {
                let i = seg.outOffset + k
                let pos = seg.sourceStart + Double(k) * perFrame, next = pos + perFrame
                if metronome.enabled, beatFrames > 0 {
                    let origin = Double(metronome.originFrame)
                    if floor((next - origin) / beatFrames) > floor((pos - origin) / beatFrames) {
                        clickRemaining = Int(sampleRate * 0.03); clickPhase = 0; clickCount += 1
                        if let anchor = metronome.barAnchorFrame {
                            let m = ((next - Double(anchor)) / beatFrames).rounded().truncatingRemainder(dividingBy: metronome.beatsPerBar)
                            clickAccent = abs(m) < 0.5
                        } else { clickAccent = false }
                    }
                    if clickRemaining > 0 {
                        let env = Float(clickRemaining) / Float(sampleRate * 0.03)
                        let s = Float(sin(clickPhase)) * env * env * metronome.volume * 0.5
                        clickPhase += 2 * .pi * (clickAccent ? 1760.0 : 1100.0) / sampleRate
                        left[i] += s; right[i] += s; clickRemaining -= 1
                    }
                }
                if midiEnabled {
                    while eventCursor < events.count, Double(events[eventCursor].frame) < next {
                        let e = events[eventCursor]
                        if Double(e.frame) >= pos {
                            let t = AUEventSampleTimeImmediate + AUEventSampleTime(i)
                            if e.drum {
                                var bytes: [UInt8] = e.on ? [0x99, e.pitch, e.velocity] : [0x89, e.pitch, 0]
                                drumSchedule?(t, 0, 3, &bytes)
                                if e.on { activeDrums.insert(e.pitch) } else { activeDrums.remove(e.pitch) }
                            } else {
                                var bytes: [UInt8] = e.on ? [0x90, e.pitch, e.velocity] : [0x80, e.pitch, 0]
                                schedule?(t, 0, 3, &bytes)
                                if e.on { activeNotes.insert(e.pitch) } else { activeNotes.remove(e.pitch) }
                            }
                        }
                        eventCursor += 1
                    }
                }
            }
        }
        if rendered.wrapped {
            // The next round's gate takes over here, in the audio thread, not when the main
            // thread gets round to it.
            wrapCount += 1
            gate = gateAfterWrap
        }
        position = Int64(stretch.position)
        if loop == nil, lengthFrames > 0, position >= lengthFrames {
            playing = false
            for p in activeNotes { var b: [UInt8] = [0x80, p, 0]; schedule?(AUEventSampleTimeImmediate, 0, 3, &b) }
            for p in activeDrums { var b: [UInt8] = [0x89, p, 0]; drumSchedule?(AUEventSampleTimeImmediate, 0, 3, &b) }
            activeNotes.removeAll(); activeDrums.removeAll()
        }
    }

    // MARK: Previews (main thread)

    /// Plays one pitch until `stopPreview`, closing any previous preview first.
    func preview(pitch: Int, exclusive: Bool = true) {
        start()
        if exclusive { stopPreview() }
        let p = UInt8(clamping: pitch)
        sampler.startNote(p, withVelocity: 100, onChannel: 1)
        previewing.insert(p)
    }

    /// One key pressed on an on-screen keyboard: it rings for a moment without cutting off
    /// whatever else is sounding, so keys can be played one after another.
    func tapKey(_ pitch: Int, seconds: Double = 1.2) {
        start()
        let p = UInt8(clamping: pitch)
        sampler.stopNote(p, onChannel: 1)
        sampler.startNote(p, withVelocity: 96, onChannel: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.sampler.stopNote(p, onChannel: 1) }
    }

    func stopPreview() {
        for p in previewing { sampler.stopNote(p, onChannel: 1) }
        previewing.removeAll()
    }

    private var chordTask: Task<Void, Never>?
    private var chordGeneration = 0

    /// Plays notes with relative timing (seconds). A new call cuts the previous one off
    /// immediately; the old task must never send its pending note-offs, or it would
    /// silence the same pitches in the new chord.
    func playNotes(_ notes: [(pitch: Int, start: Double, duration: Double, velocity: Int)]) {
        start()
        chordTask?.cancel()
        chordGeneration += 1
        let generation = chordGeneration
        stopPreview()
        sampler.sendController(123, withValue: 0, onChannel: 1)
        let sorted = notes.sorted { $0.start < $1.start }
        chordTask = Task { @MainActor [weak self] in
            guard let self else { return }
            func current() -> Bool { !Task.isCancelled && self.chordGeneration == generation }
            let t0 = Date()
            var offs: [(Double, UInt8)] = []
            for n in sorted {
                let wait = n.start - Date().timeIntervalSince(t0)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                guard current() else { return }
                // Fire due note-offs first.
                let now = Date().timeIntervalSince(t0)
                for (t, p) in offs where t <= now { self.sampler.stopNote(p, onChannel: 1) }
                offs.removeAll { $0.0 <= now }
                let p = UInt8(clamping: n.pitch)
                self.sampler.startNote(p, withVelocity: UInt8(clamping: n.velocity), onChannel: 1)
                offs.append((n.start + n.duration, p))
            }
            for (t, p) in offs.sorted(by: { $0.0 < $1.0 }) {
                let wait = t - Date().timeIntervalSince(t0)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                guard current() else { return }
                self.sampler.stopNote(p, onChannel: 1)
            }
        }
    }

    func playChord(_ pitches: [Int], duration: Double = 1.6) {
        playNotes(pitches.map { (pitch: $0, start: 0, duration: duration, velocity: 96) })
    }

    func stopChord() {
        chordTask?.cancel()
        chordGeneration += 1
        sampler.sendController(123, withValue: 0, onChannel: 1)
    }
}

/// Loads an audio file into memory as float PCM at its own sample rate.
enum AudioLoader {
    /// A stretch of a file at `sampleRate`, resampled when the file runs at another rate, so
    /// it can share the engine's frame axis with tracks of that rate. `startUs`…`endUs` are
    /// times in the file.
    static func loadClip(_ url: URL, startUs: Int64, endUs: Int64, sampleRate: Double) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let start = Int64((Double(startUs) * rate / 1_000_000).rounded())
        let count = Int64((Double(endUs - startUs) * rate / 1_000_000).rounded())
        let raw = try load(url, startFrame: max(0, start), frames: max(0, count))
        guard rate != sampleRate else { return raw }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: raw.format.channelCount),
              let converter = AVAudioConverter(from: raw.format, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(raw.frameLength) * sampleRate / rate) + 64) else {
            throw WorkerError(code: "SOURCE_MISSING", message: "无法转换音频采样率")
        }
        nonisolated(unsafe) var fed = false
        var failure: NSError?
        let status = converter.convert(to: out, error: &failure) { _, state in
            if fed { state.pointee = .endOfStream; return nil }
            fed = true
            state.pointee = .haveData
            return raw
        }
        if status == .error { throw failure ?? WorkerError(code: "SOURCE_MISSING", message: "音频采样率转换失败") }
        return out
    }

    static func load(_ url: URL, startFrame: Int64 = 0, frames: Int64? = nil) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let total = frames ?? (file.length - startFrame)
        let count = AVAudioFrameCount(max(0, min(total, file.length - startFrame)))
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: max(count, 1)) else {
            throw WorkerError(code: "SOURCE_MISSING", message: "无法分配音频缓冲")
        }
        file.framePosition = startFrame
        try file.read(into: buf, frameCount: count)
        return buf
    }
}
