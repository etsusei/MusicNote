import Foundation

/// A clip's loudness across its length, for the practice timeline to draw under the playhead.
public enum Waveform {
    /// How loud each of `buckets` equal stretches is (its RMS, the louder channel's), scaled
    /// so the loudest stretch is 1 and gently lifted so quiet passages still show next to a
    /// loud chorus. Empty when there is no sound to draw.
    public static func peaks(channels: [UnsafeBufferPointer<Float>], buckets: Int) -> [Float] {
        let frames = channels.map(\.count).min() ?? 0
        guard buckets > 0, frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: buckets)
        for c in channels {
            for b in 0..<buckets {
                let lo = min(frames - 1, frames * b / buckets), hi = min(frames, max(lo + 1, frames * (b + 1) / buckets))
                var sum: Float = 0
                for i in lo..<hi { sum += c[i] * c[i] }
                out[b] = max(out[b], (sum / Float(hi - lo)).squareRoot())
            }
        }
        guard let top = out.max(), top > 1e-4 else { return [] }
        return out.map { Float(pow(Double($0 / top), 0.7)) }
    }

    /// `peaks` resampled to `count` columns, each the loudest of the buckets it covers.
    public static func columns(_ peaks: [Float], count: Int) -> [Float] {
        guard count > 0, !peaks.isEmpty else { return [] }
        return (0..<count).map { k in
            let lo = peaks.count * k / count, hi = max(lo + 1, peaks.count * (k + 1) / count)
            return peaks[lo..<min(hi, peaks.count)].max() ?? 0
        }
    }
}
