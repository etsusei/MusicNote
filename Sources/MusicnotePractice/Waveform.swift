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

    /// A stretch of the clip drawn as one column, and how loud it is.
    public struct Column: Equatable, Sendable {
        public var startUs: Int64, endUs: Int64
        public var value: Float
        public init(startUs: Int64, endUs: Int64, value: Float) { self.startUs = startUs; self.endUs = endUs; self.value = value }
    }

    /// `peaks` (spread evenly over the clip) cut along the beat grid: columns `unitUs` long
    /// from `originUs`, the first and last cut short at the clip's ends, each the loudest of
    /// the peaks it covers.
    public static func columns(_ peaks: [Float], durationUs: Int64, originUs: Int64, unitUs: Double) -> [Column] {
        guard !peaks.isEmpty, durationUs > 0, unitUs >= 1_000 else { return [] }
        let n = peaks.count, d = Double(durationUs)
        var out: [Column] = []
        var k = Int(floor(Double(-originUs) / unitUs))
        while true {
            let t = originUs + Int64((Double(k) * unitUs).rounded())
            if t >= durationUs { break }
            let s = max(0, t), e = min(durationUs, originUs + Int64((Double(k + 1) * unitUs).rounded()))
            if e > s {
                let lo = min(n - 1, Int(Double(s) / d * Double(n)))
                let hi = min(n, max(lo + 1, Int((Double(e) / d * Double(n)).rounded(.up))))
                out.append(Column(startUs: s, endUs: e, value: peaks[lo..<hi].max() ?? 0))
            }
            k += 1
        }
        return out
    }

    /// How many beats one column spans so that columns are about `minWidth` wide or more:
    /// a whole number of beats that sits evenly in the bar where it can, or a half, quarter,
    /// eighth of a beat when beats are wide.
    public static func beatsPerColumn(beatWidth: Double, beatsPerBar: Double, minWidth: Double = 2.5) -> Double {
        guard beatWidth > 0 else { return 1 }
        if beatWidth >= minWidth * 2 {
            return 1 / ([8.0, 4, 2].first { beatWidth / $0 >= minWidth } ?? 1)
        }
        let whole = (beatsPerBar - beatsPerBar.rounded()).magnitude < 1e-6 ? max(1, beatsPerBar.rounded()) : 0
        var options: [Double] = [1]
        if whole > 0 {
            if Int(whole) % 2 == 0 { options.append(2) }
            options += [whole, whole * 2, whole * 4, whole * 8, whole * 16]
        } else {
            options += [2, 4, 8, 16, 32, 64]
        }
        return options.first { $0 * beatWidth >= minWidth } ?? options.last!
    }
}
