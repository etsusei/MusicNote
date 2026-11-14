import AVFoundation
import Foundation
import RubberBand

/// Slows a whole piece of audio down (or speeds it up) without changing its pitch, with the
/// stretcher's better engine and not in real time: it knows the whole length beforehand, so
/// the result is exactly `timeRatio` times as long and a moment at `t` lands at `t × timeRatio`.
public enum OfflineStretch {
    public struct Failure: Error, LocalizedError {
        public var errorDescription: String? { "变速处理音频失败" }
    }

    /// Feeds audio in and takes the stretched audio out, a block at a time.
    private final class Stretcher {
        private let state: RubberBandState
        private let target: Int
        private var written = 0
        private var outL: [Float], outR: [Float]
        /// Frames given to the stretcher at a time; it is told so and sizes its buffers for it.
        private static let block = 8_192

        init?(sampleRate: Double, frames: Int, timeRatio: Double) {
            let options = RubberBandOptionProcessOffline.rawValue | RubberBandOptionEngineFiner.rawValue
                | RubberBandOptionChannelsTogether.rawValue
            guard let s = rubberband_new(UInt32(sampleRate), 2, Int32(options), timeRatio, 1) else { return nil }
            state = s
            rubberband_set_expected_input_duration(s, UInt32(frames))
            rubberband_set_max_process_size(s, UInt32(Self.block))
            target = Int((Double(frames) * timeRatio).rounded())
            outL = [Float](repeating: 0, count: 65_536); outR = outL
        }

        deinit { rubberband_delete(state) }

        /// One block in; whatever is ready comes out through `take`. After the final block the
        /// output is made exactly the promised length.
        func feed(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, count: Int, final: Bool,
                  take: (UnsafePointer<Float>, UnsafePointer<Float>, Int) throws -> Void) rethrows {
            var done = 0
            repeat {
                let n = min(count - done, Self.block)
                let last = final && done + n == count
                var pair: [UnsafePointer<Float>?] = [l + done, r + done]
                rubberband_process(state, &pair, UInt32(n), last ? 1 : 0)
                done += n
                try drain(take)
            } while done < count
            guard final else { return }
            // Short by a rounding: silence to the end.
            let capacity = outL.count
            for i in 0..<capacity { outL[i] = 0; outR[i] = 0 }
            while written < target {
                let n = min(target - written, capacity)
                try outL.withUnsafeBufferPointer { a in try outR.withUnsafeBufferPointer { b in try take(a.baseAddress!, b.baseAddress!, n) } }
                written += n
            }
        }

        private func drain(_ take: (UnsafePointer<Float>, UnsafePointer<Float>, Int) throws -> Void) rethrows {
            let capacity = outL.count
            while true {
                let available = Int(rubberband_available(state))
                guard available > 0 else { return }
                var got = 0
                outL.withUnsafeMutableBufferPointer { a in
                    outR.withUnsafeMutableBufferPointer { b in
                        var pair: [UnsafeMutablePointer<Float>?] = [a.baseAddress, b.baseAddress]
                        got = Int(rubberband_retrieve(state, &pair, UInt32(min(available, capacity))))
                    }
                }
                guard got > 0 else { return }
                let keep = min(got, target - written)
                if keep > 0 {
                    try outL.withUnsafeBufferPointer { a in try outR.withUnsafeBufferPointer { b in try take(a.baseAddress!, b.baseAddress!, keep) } }
                    written += keep
                }
            }
        }
    }

    /// Audio held in memory, stretched.
    public static func stretch(left: [Float], right: [Float], sampleRate: Double, timeRatio: Double) -> (left: [Float], right: [Float]) {
        let frames = min(left.count, right.count)
        guard frames > 0, let s = Stretcher(sampleRate: sampleRate, frames: frames, timeRatio: timeRatio) else { return ([], []) }
        var l: [Float] = [], r: [Float] = []
        l.reserveCapacity(Int(Double(frames) * timeRatio) + 1); r.reserveCapacity(l.capacity)
        left.withUnsafeBufferPointer { a in
            right.withUnsafeBufferPointer { b in
                s.feed(a.baseAddress!, b.baseAddress!, count: frames, final: true) { x, y, n in
                    l.append(contentsOf: UnsafeBufferPointer(start: x, count: n))
                    r.append(contentsOf: UnsafeBufferPointer(start: y, count: n))
                }
            }
        }
        return (l, r)
    }

    /// A stereo audio file stretched into a 24-bit WAV at the same sample rate, read and
    /// written a piece at a time.
    public static func stretchFile(_ input: URL, to output: URL, timeRatio: Double) throws {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let frames = Int(file.length)
        guard format.channelCount >= 1, frames > 0,
              let s = Stretcher(sampleRate: format.sampleRate, frames: frames, timeRatio: timeRatio),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2) else { throw Failure() }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let out = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block: AVAudioFrameCount = 65_536
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: block) else { throw Failure() }
        var read = 0
        while read < frames {
            try file.read(into: inBuffer, frameCount: min(block, AVAudioFrameCount(frames - read)))
            let n = Int(inBuffer.frameLength)
            guard n > 0, let data = inBuffer.floatChannelData else { throw Failure() }
            read += n
            let l = UnsafePointer(data[0]), r = UnsafePointer(format.channelCount > 1 ? data[1] : data[0])
            try s.feed(l, r, count: n, final: read >= frames) { x, y, count in
                var done = 0
                while done < count {
                    let m = min(count - done, Int(block))
                    guard let o = outBuffer.floatChannelData else { throw Failure() }
                    o[0].update(from: x + done, count: m); o[1].update(from: y + done, count: m)
                    outBuffer.frameLength = AVAudioFrameCount(m)
                    try out.write(from: outBuffer)
                    done += m
                }
            }
        }
    }
}
