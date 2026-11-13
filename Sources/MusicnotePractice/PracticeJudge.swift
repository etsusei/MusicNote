import Foundation
import MusicnoteCore

/// Whether a key pressed on the connected keyboard is one the music asks for. A press is
/// right when a note of that pitch starts within the tolerance of it, or is already sounding
/// (a late press of a held note); anything else is wrong. Keys are judged as they go down and
/// keep their verdict until released.
public struct PracticeJudge: Sendable {
    public enum Verdict: Sendable { case hit, wrong }

    /// How far from a note's start a press may be and still count, in real seconds; at half
    /// speed the same reach covers half as much of the music.
    public static let toleranceSeconds = 0.18

    public private(set) var held: [Int: Verdict] = [:]
    public private(set) var hits = 0
    public private(set) var wrongs = 0

    public init() {}

    /// A key goes down at `us` of the music, playing at `rate`.
    @discardableResult
    public mutating func keyDown(_ pitch: Int, atUs us: Int64, rate: Double, in timeline: NoteTimeline) -> Verdict {
        let reach = Int64(Self.toleranceSeconds * max(rate, 0.1) * 1_000_000)
        let near = timeline.visible(fromUs: us - reach, toUs: us + reach + 1)
        let right = near.contains { i in
            let n = timeline.notes[i]
            return n.pitch == pitch && us >= n.startUs - reach && us < max(n.endUs, n.startUs + reach)
        }
        let verdict: Verdict = right ? .hit : .wrong
        held[pitch] = verdict
        if right { hits += 1 } else { wrongs += 1 }
        return verdict
    }

    public mutating func keyUp(_ pitch: Int) { held[pitch] = nil }

    public mutating func releaseAll() { held = [:] }
}
