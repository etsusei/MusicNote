import Foundation

/// The clip's harmony while it is being checked: a model result not yet confirmed, or the
/// confirmed harmony opened for changes. At most one per clip. Nothing the user owns changes
/// until it is confirmed; discarding just deletes it.
public struct HarmonyDraft: Record {
    public static let kind = "harmony.draft"
    public var id: UUID
    public var analysisId: UUID
    /// The confirmed revision it was opened from (nil for the first one).
    public var baseRevision: Int?
    public var harmony: HarmonyRevision
    /// Notes rewritten with standard voicings by renames/adds; a MIDI revision on confirm.
    public var draftNotes: [MidiNote]?
    /// Set when the draft is a model analysis result (its checking material lives in `harmony.auto`).
    public var runId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(analysisId: UUID, baseRevision: Int?, harmony: HarmonyRevision, runId: UUID?) {
        id = UUID(); self.analysisId = analysisId; self.baseRevision = baseRevision; self.harmony = harmony
        self.runId = runId; createdAt = Date(); updatedAt = Date()
    }

    public var ownerId: UUID? { analysisId }
    public var sortKey: Double { createdAt.timeIntervalSince1970 }
    public var fromModel: Bool { runId != nil }
}

public enum DraftCommit {
    /// Confirms a draft: rewritten notes become a confirmed MIDI revision, the draft becomes the
    /// next harmony revision (degrees in the current key, checking points cleared), the item
    /// points at it, and the draft is removed. Older revisions stay.
    @discardableResult
    public static func commit(_ d: HarmonyDraft, store: Store) throws -> HarmonyRevision {
        guard var item = store.fetch(AnalysisItem.self, id: d.analysisId) else {
            throw WorkerError(code: "SOURCE_MISSING", message: "找不到这个片段")
        }
        var rev = d.harmony
        if let notes = d.draftNotes, let r = item.confirmedMidiRevision,
           let midi = store.all(MidiRevision.self, owner: item.id).first(where: { $0.revision == r }) {
            let next = (store.all(MidiRevision.self, owner: item.id).map(\.revision).max() ?? 0) + 1
            var m = MidiRevision(analysisId: item.id, revision: next, status: .confirmed, parentRevision: midi.revision, stem: midi.stem,
                                 transcriber: midi.transcriber.merging(["edit": "改和弦名后用标准按法改写"]) { $1 }, notes: notes)
            m.confirmedAt = Date()
            try store.save(m)
            item.confirmedMidiRevision = next
            rev.midiRevision = next
        }
        let latest = store.all(HarmonyRevision.self, owner: item.id).map(\.revision).max() ?? 0
        rev.id = UUID()
        rev.revision = latest + 1
        rev.createdAt = Date()
        rev.timingRevision = item.timingRevision
        if let key = item.timing?.key {
            rev.key = key
            for i in rev.events.indices { rev.events[i].degree = rev.events[i].symbol.flatMap { Degrees.label(symbol: $0, key: key) } }
        }
        if let run = d.runId { rev.params["adoptedFrom"] = run.uuidString }
        rev.auto?.toConfirm = [] // checked
        try store.save(rev)
        item.harmonyRevision = rev.revision
        item.updatedAt = Date()
        try store.save(item)
        try store.delete(HarmonyDraft.self, id: d.id)
        return rev
    }
}
