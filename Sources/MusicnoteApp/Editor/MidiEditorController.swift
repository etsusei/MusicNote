import Foundation
import MusicnoteCore
import Observation

/// Note editing state with snapshot-based undo. One drag is one command.
@MainActor @Observable
final class MidiEditorController {
    var notes: [MidiNote] = []
    var selected: Set<UUID> = []
    var snapDivision = 0 // 0 = off, 1 = 1/4, 2 = 1/8, 4 = 1/16, 8 = 1/32
    var grid: BeatGrid?
    var durationUs: Int64 = 0
    var loop: Range<Int64>? // µs, clip-local
    private(set) var undoStack: [[MidiNote]] = []
    private(set) var redoStack: [[MidiNote]] = []
    var onChange: (([MidiNote]) -> Void)?
    var version = 0

    func load(_ notes: [MidiNote], grid: BeatGrid?, durationUs: Int64) {
        self.notes = notes.sorted { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }
        self.grid = grid; self.durationUs = durationUs
        undoStack = []; redoStack = []; selected = []
        version += 1
    }

    /// Call before a mutation that should be undoable as one step.
    func beginCommand() {
        undoStack.append(notes)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack = []
    }

    func commit() {
        version += 1
        onChange?(notes)
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(notes); notes = prev
        selected = selected.filter { id in notes.contains { $0.id == id } }
        commit()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(notes); notes = next
        commit()
    }

    func popUndoForNoop() -> Bool {
        guard !undoStack.isEmpty else { return false }
        undoStack.removeLast()
        return true
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func snap(_ us: Int64) -> Int64 {
        guard snapDivision > 0, let grid else { return us }
        return grid.snap(us: us, division: snapDivision)
    }

    var snapStepUs: Int64 {
        guard let grid else { return 125_000 }
        return Int64(grid.beatUs / Double(max(1, snapDivision == 0 ? 4 : snapDivision)))
    }

    func index(_ id: UUID) -> Int? { notes.firstIndex { $0.id == id } }

    func update(_ id: UUID, _ f: (inout MidiNote) -> Void) {
        guard let i = index(id) else { return }
        f(&notes[i])
        notes[i].edited = true
        version += 1
    }

    func add(pitch: Int, startUs: Int64, durationUs: Int64) -> UUID {
        beginCommand()
        let n = MidiNote(pitch: pitch, startUs: max(0, startUs), endUs: max(startUs + 10_000, startUs + durationUs), instrument: "manual", edited: true)
        notes.append(n)
        notes.sort { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }
        selected = [n.id]
        commit()
        return n.id
    }

    func deleteSelected() {
        guard !selected.isEmpty else { return }
        beginCommand()
        notes.removeAll { selected.contains($0.id) }
        selected = []
        commit()
    }

    func transposeSelected(_ semitones: Int) {
        guard !selected.isEmpty else { return }
        beginCommand()
        for id in selected { update(id) { $0.pitch = min(127, max(0, $0.pitch + semitones)) } }
        commit()
    }

    func nudgeSelected(_ us: Int64) {
        guard !selected.isEmpty else { return }
        beginCommand()
        for id in selected { update(id) { n in let d = n.durationUs; n.startUs = max(0, n.startUs + us); n.endUs = n.startUs + d } }
        commit()
    }
}
