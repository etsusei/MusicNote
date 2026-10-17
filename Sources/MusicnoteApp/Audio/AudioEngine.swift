import AudioToolbox
import AVFoundation
import Foundation
import MusicnoteCore
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
    private var sourceNode: AVAudioSourceNode?
    private(set) var sampleRate: Double = 44100

    private var lock = os_unfair_lock()
    // Render state (guarded by lock)
    private var tracks: [AudioTrack] = []
    private var events: [(frame: Int64, pitch: UInt8, velocity: UInt8, on: Bool)] = []
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
    private var needsAllOff = false

    private(set) var instrument: Instrument = .piano
    private var soundFont: URL?
    private var previewing = Set<UInt8>()

    private init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        configure(sampleRate: 44100)
    }

    func start() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    /// Rebuilds the source node for a sample rate (song files may be 48 kHz; stems are 44.1 kHz).
    func configure(sampleRate rate: Double) {
        if sourceNode != nil, rate == sampleRate { return }
        if let n = sourceNode { engine.detach(n) }
        sampleRate = rate
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

    func setTracks(_ new: [AudioTrack]) {
        os_unfair_lock_lock(&lock)
        tracks = new
        lengthFrames = new.map(\.frames).max() ?? 0
        os_unfair_lock_unlock(&lock)
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

    func setMidi(_ notes: [ScheduledNote], enabled: Bool) {
        var ev: [(Int64, UInt8, UInt8, Bool)] = []
        for n in notes {
            ev.append((n.startFrame, n.pitch, n.velocity, true))
            ev.append((max(n.endFrame, n.startFrame + 1), n.pitch, 0, false))
        }
        // Offs before ons at the same frame so repeated notes retrigger.
        ev.sort { $0.0 != $1.0 ? $0.0 < $1.0 : (!$0.3 && $1.3) }
        os_unfair_lock_lock(&lock)
        events = ev.map { (frame: $0.0, pitch: $0.1, velocity: $0.2, on: $0.3) }
        midiEnabled = enabled
        eventCursor = cursorIndex(for: position)
        needsAllOff = true
        lengthFrames = max(lengthFrames, notes.map(\.endFrame).max() ?? 0)
        os_unfair_lock_unlock(&lock)
    }

    func setLength(_ frames: Int64) {
        os_unfair_lock_lock(&lock); lengthFrames = frames; os_unfair_lock_unlock(&lock)
    }

    func setMidiMix(muted: Bool, solo: Bool) {
        os_unfair_lock_lock(&lock); midiMuted = muted; midiSolo = solo; os_unfair_lock_unlock(&lock)
        sampler.volume = midiAudible ? 1 : 0
    }

    private var midiAudible: Bool {
        let anySolo = midiSolo || tracks.contains { $0.solo }
        return !midiMuted && (!anySolo || midiSolo)
    }

    func setMetronome(_ m: MetronomeConfig) {
        os_unfair_lock_lock(&lock); metronome = m; os_unfair_lock_unlock(&lock)
    }

    func setLoop(_ range: Range<Int64>?) {
        os_unfair_lock_lock(&lock); loop = range; os_unfair_lock_unlock(&lock)
    }

    // MARK: Transport

    func play(from frame: Int64? = nil) {
        start()
        os_unfair_lock_lock(&lock)
        if let frame { position = max(0, frame); eventCursor = cursorIndex(for: position); needsAllOff = true }
        // A position left over from a longer source (e.g. the whole song) restarts at the top.
        if lengthFrames > 0, position >= lengthFrames {
            position = loop?.lowerBound ?? 0; eventCursor = cursorIndex(for: position); needsAllOff = true
        }
        playing = true
        os_unfair_lock_unlock(&lock)
    }

    func pause() {
        os_unfair_lock_lock(&lock); playing = false; needsAllOff = true; os_unfair_lock_unlock(&lock)
        allNotesOff()
    }

    func seek(_ frame: Int64) {
        os_unfair_lock_lock(&lock)
        position = max(0, frame); eventCursor = cursorIndex(for: position); needsAllOff = true
        os_unfair_lock_unlock(&lock)
    }

    var isPlaying: Bool { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return playing }
    var positionFrames: Int64 { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return position }

    func stopAll() {
        pause()
        setTracks([]); setMidi([], enabled: false); setLoop(nil)
        setMetronome(MetronomeConfig())
    }

    private func cursorIndex(for frame: Int64) -> Int {
        var lo = 0, hi = events.count
        while lo < hi { let mid = (lo + hi) / 2; if events[mid].frame < frame { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    private func allNotesOff() {
        for ch: UInt8 in 0...1 { sampler.sendController(123, withValue: 0, onChannel: ch) }
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
        if needsAllOff {
            needsAllOff = false
            for p in activeNotes { var b: [UInt8] = [0x80, p, 0]; schedule?(AUEventSampleTimeImmediate, 0, 3, &b) }
            activeNotes.removeAll()
        }
        guard playing else { return }

        let anySolo = tracks.contains { $0.solo } || midiSolo
        let beatFrames = metronome.bpm > 0 ? sampleRate * 60 / metronome.bpm : 0
        var pos = position
        for i in 0..<frameCount {
            if let loop, pos >= loop.upperBound || pos < loop.lowerBound {
                // Loop wrap: silence hanging notes, then continue from the loop start.
                for p in activeNotes { var b: [UInt8] = [0x80, p, 0]; schedule?(AUEventSampleTimeImmediate + AUEventSampleTime(i), 0, 3, &b) }
                activeNotes.removeAll()
                pos = loop.lowerBound
                eventCursor = cursorIndex(for: pos)
            } else if loop == nil, pos >= lengthFrames, lengthFrames > 0 {
                playing = false
                for p in activeNotes { var b: [UInt8] = [0x80, p, 0]; schedule?(AUEventSampleTimeImmediate + AUEventSampleTime(i), 0, 3, &b) }
                activeNotes.removeAll()
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
                    clickRemaining = Int(sampleRate * 0.03); clickPhase = 0
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
                        var bytes: [UInt8] = e.on ? [0x90, e.pitch, e.velocity] : [0x80, e.pitch, 0]
                        schedule?(AUEventSampleTimeImmediate + AUEventSampleTime(i), 0, 3, &bytes)
                        if e.on { activeNotes.insert(e.pitch) } else { activeNotes.remove(e.pitch) }
                    }
                    eventCursor += 1
                }
            }
            pos += 1
        }
        position = pos
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
