import AVFoundation
import Foundation
import MusicnoteCore

/// The confirmed harmony played over the original: the clip's audio, and each chord (as struck
/// in the MIDI, else the standard voicing) on the grid where the bars show it: an anticipation
/// on the beat it anticipates, ringing until the next chord. Same timing as 灵感进行.
extension AppModel {
    func playAlong(_ itemId: UUID, harmony: HarmonyRevision, fromUs: Int64 = 0) {
        guard let item = item(itemId), let url = Pipeline.resolve(item.source) else {
            alert = AppAlert(title: "无法播放", message: "找不到原曲文件"); return
        }
        let buffer: AVAudioPCMBuffer
        if let b = auditionCache[url.path] { buffer = b } else {
            guard let b = try? AudioLoader.load(url) else { return }
            auditionCache = [url.path: b]
            buffer = b
        }
        let rate = buffer.format.sampleRate
        func frame(_ clipUs: Int64) -> Int64 { Int64(Double(item.trimStartUs + clipUs) / 1e6 * rate) }
        let midi = confirmedMidi(item)?.notes ?? []
        let beatUs = item.timing?.grid.beatUs ?? 600_000
        let fold = UserDefaults.standard.object(forKey: "foldPushes") as? Bool ?? true
        let spans = HarmonySection.grid(item, harmony).map { BarEvidence.readingSpans(harmony.events, grid: $0, foldPushes: fold) }
            ?? harmony.events.map { (ev: $0, s: $0.startUs, e: $0.endUs, pushed: false) }
        var scheduled: [ScheduledNote] = []
        var heard: [String: [Int]] = [:]
        for (ev, s, end, _) in spans {
            guard let pitches = HeardVoicing.pitches(ev, notes: midi, beatUs: beatUs) else { continue }
            heard[ev.id] = pitches
            let a = frame(s), b = max(a + 1, frame(end - 20_000))
            for p in pitches where (0...127).contains(p) {
                scheduled.append(ScheduledNote(startFrame: a, endFrame: b, pitch: UInt8(p), velocity: 72))
            }
        }
        let e = AudioEngine.shared
        e.pause()
        e.configure(sampleRate: rate)
        e.setMetronome(MetronomeConfig())
        let original = AudioTrack(id: "original", buffer: buffer)
        original.gain = Self.playAlongOriginalGain
        e.setTracks([original])
        e.setMidi(scheduled, enabled: true)
        e.setLength(frame(item.durationUs))
        e.setLoop(nil)
        auditionStop?.cancel()
        playAlongItem = itemId
        playAlongSpans = spans.map { (id: $0.ev.id, startUs: $0.s, endUs: $0.e) }
        playAlongPitches = heard
        e.play(from: frame(max(0, fromUs)))
    }

    /// Volume of the original under the chords (0–1), remembered between sessions.
    static var playAlongOriginalGain: Float {
        get { UserDefaults.standard.object(forKey: "playAlongOriginalGain") as? Float ?? 0.8 }
        set { UserDefaults.standard.set(newValue, forKey: "playAlongOriginalGain") }
    }

    func setPlayAlongOriginalGain(_ g: Float) {
        Self.playAlongOriginalGain = g
        AudioEngine.shared.updateTrack("original", gain: g)
    }

    /// Lights a chord on the keyboard (clicked or sounding); the one before stays as a shadow.
    func light(_ itemId: UUID, eventId: String, pitches: [Int]) {
        if let l = litChord, l.itemId == itemId, l.eventId == eventId, l.pitches == pitches { return }
        let previous = litChord?.itemId == itemId ? litChord?.pitches ?? [] : []
        litChord = LitChord(itemId: itemId, eventId: eventId, pitches: pitches, previous: previous)
    }

    func stopPlayAlong() {
        AudioEngine.shared.pause()
        playAlongItem = nil
    }
}
