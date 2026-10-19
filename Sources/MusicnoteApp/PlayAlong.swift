import AVFoundation
import Foundation
import MusicnoteCore

/// The confirmed harmony played over the original: the clip's audio with each chord sounding
/// (as struck in the MIDI, else the standard voicing) from its start to its end.
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
        let window = min(0.6, (item.timing?.grid.beatUs ?? 600_000) / 1e6)
        var scheduled: [ScheduledNote] = []
        for ev in harmony.events {
            let rel: [PlayedVoicing.Note] = midi.filter { ev.noteIds.contains($0.id) }.map { n in
                let st = max(n.startUs, ev.startUs)
                return (pitch: n.pitch, start: Double(st - ev.startUs) / 1e6, duration: Double(min(n.endUs, ev.endUs) - st) / 1e6)
            }
            guard let pitches = PlayedVoicing.pitches(symbol: ev.symbol, notes: rel, onsetWindow: window)
                    ?? ev.symbol.flatMap(StandardVoicing.pitches(symbol:)) else { continue }
            let a = frame(ev.startUs), b = max(a + 1, frame(ev.endUs - 20_000))
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

    func stopPlayAlong() {
        AudioEngine.shared.pause()
        playAlongItem = nil
    }
}
