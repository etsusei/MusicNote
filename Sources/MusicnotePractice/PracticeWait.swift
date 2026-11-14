import Foundation
import MusicnoteCore

/// Wait mode: the music stops at each note until its key is pressed, and goes on when it is.
/// This keeps which notes have been played; the engine does the stopping, at the place this
/// names (`awaitedUs`).
///
/// A key counts for the earliest note of its pitch that is still owed and has started, or
/// starts within the judge's reach: a press a little early is taken, and one however late,
/// since the music is standing there for it. A press counts for one note only.
///
/// With a loop, only the loop's own notes are waited for (not the lead-in bar before it), and
/// every round asks for all of them again.
public struct WaitGate: Sendable {
    /// How far past a note's start the music runs before it stops for it, in real seconds.
    /// Someone playing in time presses a few hundredths of a second late about as often as
    /// early; stopping dead on the note would stutter the music on every such press.
    public static let graceSeconds = 0.08

    public let timeline: NoteTimeline
    /// Notes played in this round, and those of the next round played just before it began.
    private var done: Set<Int> = []
    private var doneNext: Set<Int> = []
    /// Notes before this are not waited for in this round (it began mid-way: a seek, or
    /// waiting was turned on here).
    private var floorUs: Int64 = 0
    private var loop: Range<Int64>?
    /// Where a round starts playing: the loop's start, or a bar earlier with the lead-in.
    private var wrapToUs: Int64 = 0

    public init(timeline: NoteTimeline) { self.timeline = timeline }

    /// Starts afresh from a position: after a seek, a change of the loop, or turning waiting on.
    public mutating func restart(fromUs: Int64, loop: Range<Int64>?, wrapToUs: Int64 = 0) {
        done = []; doneNext = []
        floorUs = fromUs
        self.loop = loop
        self.wrapToUs = wrapToUs
    }

    /// The loop came round: everything in it is owed again, less what was pressed just ahead.
    public mutating func wrapped() {
        done = doneNext; doneNext = []
        floorUs = loop?.lowerBound ?? 0
    }

    private var lowerUs: Int64 { max(floorUs, loop?.lowerBound ?? 0) }
    private var upperUs: Int64 { loop?.upperBound ?? .max }

    private func firstOwed(from lower: Int64, skipping played: Set<Int>) -> Int? {
        var i = timeline.firstIndex(startingAtOrAfter: lower)
        while i < timeline.notes.count, timeline.notes[i].startUs < upperUs {
            if !played.contains(i) { return i }
            i += 1
        }
        return nil
    }

    /// Start of the first note still owed in this round: the music may not pass it. Nil when
    /// the rest of the round is free.
    public var awaitedUs: Int64? { firstOwed(from: lowerUs, skipping: done).map { timeline.notes[$0].startUs } }

    /// The same for the round after the loop comes round. Nil without a loop.
    public var awaitedAfterWrapUs: Int64? {
        guard let loop else { return nil }
        return firstOwed(from: loop.lowerBound, skipping: doneNext).map { timeline.notes[$0].startUs }
    }

    /// Pitches owed at a position: notes that have started and not been played.
    public func awaited(atUs us: Int64) -> Set<Int> {
        var out = Set<Int>()
        var i = timeline.firstIndex(startingAtOrAfter: lowerUs)
        while i < timeline.notes.count, timeline.notes[i].startUs < upperUs, timeline.notes[i].startUs <= us {
            if !done.contains(i) { out.insert(timeline.notes[i].pitch) }
            i += 1
        }
        return out
    }

    /// A key goes down at `us` of the music, playing at `rate`. True when a note was owed it.
    public mutating func keyDown(_ pitch: Int, atUs us: Int64, rate: Double) -> Bool {
        let reach = Int64(PracticeJudge.toleranceSeconds * max(rate, 0.1) * 1_000_000)
        var i = timeline.firstIndex(startingAtOrAfter: lowerUs)
        while i < timeline.notes.count, timeline.notes[i].startUs < upperUs, timeline.notes[i].startUs <= us + reach {
            if timeline.notes[i].pitch == pitch, !done.contains(i) { done.insert(i); return true }
            i += 1
        }
        // Just before the loop comes round: the press may be for the first notes of the next round.
        if let loop, us + reach >= loop.upperBound {
            let limit = wrapToUs + (us + reach - loop.upperBound)
            i = timeline.firstIndex(startingAtOrAfter: loop.lowerBound)
            while i < timeline.notes.count, timeline.notes[i].startUs < loop.upperBound, timeline.notes[i].startUs <= limit {
                if timeline.notes[i].pitch == pitch, !doneNext.contains(i) { doneNext.insert(i); return true }
                i += 1
            }
        }
        return false
    }
}
