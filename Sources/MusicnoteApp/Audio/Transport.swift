import AVFoundation
import Foundation
import MusicnoteCore
import Observation

/// Multi-level min/max peaks for drawing waveforms of any zoom without rescanning PCM.
final class WaveformPeaks: @unchecked Sendable {
    struct Level { let samplesPerBucket: Int; let mins: [Float]; let maxs: [Float] }
    let levels: [Level]
    let frames: Int64
    let sampleRate: Double

    init(buffer: AVAudioPCMBuffer) {
        frames = Int64(buffer.frameLength)
        sampleRate = buffer.format.sampleRate
        let n = Int(buffer.frameLength)
        let chans = Int(buffer.format.channelCount)
        let data = buffer.floatChannelData!
        var levels: [Level] = []
        var base = 64
        // Level 0 from samples, then each level aggregates 8 buckets of the previous.
        var mins = [Float](), maxs = [Float]()
        let count0 = (n + base - 1) / base
        mins.reserveCapacity(count0); maxs.reserveCapacity(count0)
        var i = 0
        while i < n {
            let end = min(n, i + base)
            var lo: Float = 0, hi: Float = 0
            for c in 0..<chans {
                let p = data[c]
                var j = i
                while j < end { let v = p[j]; if v < lo { lo = v }; if v > hi { hi = v }; j += 1 }
            }
            mins.append(lo); maxs.append(hi)
            i = end
        }
        levels.append(Level(samplesPerBucket: base, mins: mins, maxs: maxs))
        while levels.last!.mins.count > 512 {
            let prev = levels.last!
            base *= 8
            var m2 = [Float](), x2 = [Float]()
            var k = 0
            while k < prev.mins.count {
                let e = min(prev.mins.count, k + 8)
                m2.append(prev.mins[k..<e].min() ?? 0); x2.append(prev.maxs[k..<e].max() ?? 0)
                k = e
            }
            levels.append(Level(samplesPerBucket: base, mins: m2, maxs: x2))
        }
        self.levels = levels
    }

    /// Peak pairs for `columns` pixel columns covering [startFrame, endFrame).
    func columns(_ columns: Int, startFrame: Int64, endFrame: Int64) -> [(Float, Float)] {
        guard columns > 0, endFrame > startFrame else { return [] }
        let spp = Double(endFrame - startFrame) / Double(columns)
        let level = levels.last { Double($0.samplesPerBucket) <= max(spp, 64) } ?? levels[0]
        var out: [(Float, Float)] = []
        out.reserveCapacity(columns)
        for c in 0..<columns {
            let f0 = Double(startFrame) + Double(c) * spp
            let b0 = Int(f0 / Double(level.samplesPerBucket))
            let b1 = max(b0 + 1, Int((f0 + spp) / Double(level.samplesPerBucket)))
            guard b0 < level.mins.count, b0 >= 0 else { out.append((0, 0)); continue }
            let e = min(level.mins.count, b1)
            out.append((level.mins[b0..<e].min() ?? 0, level.maxs[b0..<e].max() ?? 0))
        }
        return out
    }
}

/// UI-side view of the shared transport, refreshed at display rate.
@MainActor @Observable
final class TransportModel {
    var positionFrame: Int64 = 0
    var isPlaying = false
    var sampleRate: Double = 44100
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func tick() {
        let e = AudioEngine.shared
        let p = e.positionFrames
        if p != positionFrame { positionFrame = p }
        let playing = e.isPlaying
        if playing != isPlaying { isPlaying = playing }
    }

    func stop() { timer?.invalidate(); timer = nil }

    var positionUs: Int64 { Int64(Double(positionFrame) / sampleRate * 1_000_000) }
}
