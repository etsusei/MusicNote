import Foundation
import RubberBand

/// Plays a source slower or faster without changing its pitch (Rubber Band's R3 engine, in
/// real time), and keeps the clock everything else follows: `position` is the source frame
/// being heard, so notes, lights and the loop drawn from it stay on the stretched audio at
/// any speed and through speed changes.
///
/// Not thread-safe: the owner calls everything, `render` included, under one lock. `render`
/// allocates nothing.
public final class StretchPlayer {
    /// Fills `count` frames of the source starting at `start` (silence outside the source).
    public typealias Source = (_ start: Int64, _ count: Int, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) -> Void

    /// A run of rendered output and the source range heard over it.
    public struct Segment: Sendable {
        public var outOffset = 0
        public var outCount = 0
        public var sourceStart = 0.0
        public var sourceEnd = 0.0
    }

    /// What one `render` played: two segments when the loop wrapped inside it, else one.
    public struct Rendered: Sendable {
        public var first = Segment()
        public var second = Segment()
        public var wrapped = false
    }

    public static let rateRange = 0.25...2.0
    /// Speed changes glide instead of jumping: this is the time constant, so a change is nine
    /// tenths done in a little over twice as long. Short, so dragging the speed is heard at once
    /// (the stretcher itself adds its 46 ms lead on top).
    public static let glideSeconds = 0.02
    /// Fade on each side of the loop splice, in source frames.
    static let spliceFrames = 128
    static let block = 1024

    public let sampleRate: Double
    /// Speed asked for: 1 is the original tempo, 0.5 half speed.
    public var rate: Double = 1 { didSet { rate = min(max(rate, Self.rateRange.lowerBound), Self.rateRange.upperBound) } }
    /// Speed in effect right now, gliding toward `rate`.
    public private(set) var currentRate: Double = 1
    /// Speed of what is being heard right now: `currentRate` once it has passed through the stretcher.
    public var heardRate: Double { clockRate }
    /// Source frame heard at the next output frame.
    public private(set) var position: Double = 0
    /// The source range repeated while playing. Set it through `setLoop`.
    public private(set) var loop: Range<Int64>?

    private let state: RubberBandState
    private let inL: UnsafeMutablePointer<Float>, inR: UnsafeMutablePointer<Float>
    private let scratchL: UnsafeMutablePointer<Float>, scratchR: UnsafeMutablePointer<Float>
    /// Channel pointer pairs handed to the C interface, kept so `render` builds no arrays.
    private let inPair: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let outPair: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private var feedFrame: Int64 = 0
    private var padLeft = 0
    private var discardLeft = 0
    private var fadeIn = 0

    // The stretcher works ahead of the output it hands back: a new speed is first heard
    // `lead` output frames after it is set. The clock takes each speed up at that moment,
    // not when it was set, or every speed change would leave it a little further off.
    private var lead: Int64 = 0
    private var outputClock: Int64 = 0
    private var clockRate: Double = 1
    private var queuedRate: Double = 1
    private static let pendingCapacity = 1024
    private let pendingAt: UnsafeMutablePointer<Int64>
    private let pendingRate: UnsafeMutablePointer<Double>
    private var pendingHead = 0, pendingCount = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let options = RubberBandOptionProcessRealTime.rawValue | RubberBandOptionEngineFiner.rawValue
            | RubberBandOptionChannelsTogether.rawValue | RubberBandOptionThreadingNever.rawValue
        state = rubberband_new(UInt32(sampleRate), 2, Int32(options), 1, 1)
        rubberband_set_max_process_size(state, UInt32(Self.block))
        inL = .allocate(capacity: Self.block); inR = .allocate(capacity: Self.block)
        scratchL = .allocate(capacity: Self.block); scratchR = .allocate(capacity: Self.block)
        inL.initialize(repeating: 0, count: Self.block); inR.initialize(repeating: 0, count: Self.block)
        scratchL.initialize(repeating: 0, count: Self.block); scratchR.initialize(repeating: 0, count: Self.block)
        inPair = .allocate(capacity: 2); outPair = .allocate(capacity: 2)
        inPair.initialize(repeating: nil, count: 2); outPair.initialize(repeating: nil, count: 2)
        inPair[0] = UnsafePointer(inL); inPair[1] = UnsafePointer(inR)
        pendingAt = .allocate(capacity: Self.pendingCapacity); pendingRate = .allocate(capacity: Self.pendingCapacity)
        pendingAt.initialize(repeating: 0, count: Self.pendingCapacity); pendingRate.initialize(repeating: 1, count: Self.pendingCapacity)
        seek(to: 0)
    }

    deinit {
        rubberband_delete(state)
        inL.deallocate(); inR.deallocate(); scratchL.deallocate(); scratchR.deallocate()
        inPair.deallocate(); outPair.deallocate(); pendingAt.deallocate(); pendingRate.deallocate()
    }

    /// Jumps to a source frame. The stretcher starts afresh, so the next output is that frame.
    public func seek(to frame: Double) {
        rubberband_reset(state)
        currentRate = rate
        rubberband_set_time_ratio(state, 1 / currentRate)
        position = max(0, frame)
        feedFrame = Int64(position.rounded())
        padLeft = Int(rubberband_get_preferred_start_pad(state))
        discardLeft = Int(rubberband_get_start_delay(state))
        fadeIn = 0
        lead = Int64(discardLeft)
        outputClock = 0
        clockRate = currentRate; queuedRate = currentRate
        pendingHead = 0; pendingCount = 0
    }

    /// Sets or clears the loop. Audio already inside the stretcher was read for the old loop,
    /// so playback restarts from the current position (inside the new loop, else at its start).
    public func setLoop(_ range: Range<Int64>?) {
        guard range != loop else { return }
        loop = range.flatMap { $0.count >= Int64(sampleRate / 4) ? $0 : nil }
        if let l = loop, !(Double(l.lowerBound)..<Double(l.upperBound)).contains(position) { seek(to: Double(l.lowerBound)) }
        else { seek(to: position) }
    }

    /// Renders `frames` stretched frames and advances the clock.
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, source: Source) -> Rendered {
        // Glide the speed; the clock below uses the same value the stretcher is given.
        let diff = rate - currentRate
        if abs(diff) < 0.0005 { currentRate = rate } else {
            currentRate += diff * (1 - exp(-Double(frames) / (sampleRate * Self.glideSeconds)))
        }
        rubberband_set_time_ratio(state, 1 / currentRate)
        if currentRate != queuedRate {
            queuedRate = currentRate
            if pendingCount == Self.pendingCapacity { pendingCount -= 1 } // full: the newest waiting speed gives way
            let slot = (pendingHead + pendingCount) % Self.pendingCapacity
            pendingAt[slot] = outputClock + lead; pendingRate[slot] = currentRate
            pendingCount += 1
        }

        var done = 0
        var guardCount = 0
        while done < frames {
            let available = Int(rubberband_available(state))
            if available > 0 {
                if discardLeft > 0 {
                    // The stretcher's start-up delay: output from before the first source frame.
                    let n = min(available, discardLeft, Self.block)
                    outPair[0] = scratchL; outPair[1] = scratchR
                    discardLeft -= Int(rubberband_retrieve(state, outPair, UInt32(n)))
                } else {
                    let n = min(available, frames - done)
                    outPair[0] = left + done; outPair[1] = right + done
                    done += Int(rubberband_retrieve(state, outPair, UInt32(n)))
                }
                continue
            }
            guardCount += 1
            if guardCount > 4096 { break } // never spin in the audio thread
            var n = min(max(Int(rubberband_get_samples_required(state)), 64), Self.block)
            if padLeft > 0 {
                n = min(n, padLeft)
                inL.update(repeating: 0, count: n); inR.update(repeating: 0, count: n)
                padLeft -= n
            } else {
                if let l = loop, feedFrame < l.upperBound { n = Int(min(Int64(n), l.upperBound - feedFrame)) }
                source(feedFrame, n, inL, inR)
                splice(n)
                feedFrame += Int64(n)
                if let l = loop, feedFrame == l.upperBound { feedFrame = l.lowerBound; fadeIn = Self.spliceFrames }
            }
            rubberband_process(state, inPair, UInt32(n), 0)
        }
        if done < frames {
            (left + done).update(repeating: 0, count: frames - done); (right + done).update(repeating: 0, count: frames - done)
        }

        // The clock: each stretch of output covers its length × the speed heard over it.
        var t = outputClock
        let stop = outputClock + Int64(frames)
        var advance = 0.0
        while pendingCount > 0, pendingAt[pendingHead] < stop {
            let at = max(t, pendingAt[pendingHead])
            advance += Double(at - t) * clockRate
            t = at
            clockRate = pendingRate[pendingHead]
            pendingHead = (pendingHead + 1) % Self.pendingCapacity; pendingCount -= 1
        }
        advance += Double(stop - t) * clockRate
        outputClock = stop
        var r = Rendered()
        let start = position, end = position + advance
        let heardRate = max(advance / Double(max(frames, 1)), 1e-6)
        if let l = loop, start < Double(l.upperBound), end >= Double(l.upperBound) {
            let split = min(frames, max(0, Int(((Double(l.upperBound) - start) / heardRate).rounded())))
            r.first = Segment(outOffset: 0, outCount: split, sourceStart: start, sourceEnd: Double(l.upperBound))
            position = Double(l.lowerBound) + (end - Double(l.upperBound))
            r.second = Segment(outOffset: split, outCount: frames - split, sourceStart: Double(l.lowerBound), sourceEnd: position)
            r.wrapped = true
        } else {
            r.first = Segment(outOffset: 0, outCount: frames, sourceStart: start, sourceEnd: end)
            position = end
        }
        return r
    }

    /// Short fades where the loop's end meets its start, so the join does not click.
    private func splice(_ n: Int) {
        if fadeIn > 0 {
            let k = min(n, fadeIn)
            for i in 0..<k {
                let g = Float(Self.spliceFrames - fadeIn + i) / Float(Self.spliceFrames)
                inL[i] *= g; inR[i] *= g
            }
            fadeIn -= k
        }
        guard let l = loop else { return }
        let toEnd = Int(l.upperBound - feedFrame) // frames from the first of this block to the loop end
        guard toEnd - n < Self.spliceFrames, toEnd >= n else { return }
        for i in max(0, toEnd - Self.spliceFrames)..<n {
            let g = Float(toEnd - i) / Float(Self.spliceFrames)
            inL[i] *= g; inR[i] *= g
        }
    }
}
