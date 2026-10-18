import Foundation

// MARK: - Library

public enum StemKind: String, Codable, CaseIterable, Sendable {
    case vocals, drums, bass, guitar, piano, other

    public var displayName: String {
        switch self {
        case .vocals: "人声"
        case .drums: "鼓"
        case .bass: "贝斯"
        case .guitar: "吉他"
        case .piano: "钢琴"
        case .other: "其他"
        }
    }

    /// Only these stems go through chord grouping, degrees and the LLM skeleton.
    public var isHarmonic: Bool { self == .piano || self == .guitar || self == .other }
}

public struct Song: Record, Hashable {
    public static let kind = "song"
    public var id: UUID
    public var title: String
    public var artist: String
    public var album: String
    public var coverFile: String?
    public var sortIndex: Double
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, artist: String = "", album: String = "",
                coverFile: String? = nil, sortIndex: Double = 0, tags: [String] = []) {
        self.id = id; self.title = title; self.artist = artist; self.album = album
        self.coverFile = coverFile; self.sortIndex = sortIndex; self.tags = tags
        createdAt = Date(); updatedAt = Date()
    }
    public var ownerId: UUID? { nil }
    public var sortKey: Double { sortIndex }
}

/// External reference to the user's audio file. Never a copy of it.
public struct SourceRef: Codable, Hashable, Sendable {
    public var fileName: String
    public var pathHint: String
    public var bookmark: Data?
    public var bytes: Int64
    public var durationSec: Double
    public var sampleRate: Double
    public var frames: Int64
    public var fingerprint: String

    public init(fileName: String, pathHint: String, bookmark: Data?, bytes: Int64,
                durationSec: Double, sampleRate: Double, frames: Int64, fingerprint: String) {
        self.fileName = fileName; self.pathHint = pathHint; self.bookmark = bookmark; self.bytes = bytes
        self.durationSec = durationSec; self.sampleRate = sampleRate; self.frames = frames
        self.fingerprint = fingerprint
    }
}

public enum Mode: String, Codable, Sendable { case major, minor }

public struct KeySignature: Codable, Hashable, Sendable {
    public var tonic: Int // pitch class 0...11
    public var tonicName: String // spelling as confirmed, e.g. "E♭"
    public var mode: Mode

    public init(tonic: Int, tonicName: String, mode: Mode) {
        self.tonic = ((tonic % 12) + 12) % 12; self.tonicName = tonicName; self.mode = mode
    }

    public var display: String { tonicName + (mode == .major ? " 大调" : " 小调") }
}

public struct Meter: Codable, Hashable, Sendable {
    public var numerator: Int
    public var denominator: Int
    public init(_ numerator: Int, _ denominator: Int) { self.numerator = numerator; self.denominator = denominator }
    public static let fourFour = Meter(4, 4)
    /// Quarter-note beats per bar: n × 4 / d.
    public var quarterBeatsPerBar: Double { Double(numerator) * 4 / Double(denominator) }
    public var display: String { "\(numerator)/\(denominator)" }
}

public struct Detection: Codable, Hashable, Sendable {
    public var trimRevision: Int
    public var rawBpm: Double?
    public var roundedBpm: Double?
    public var ticksSec: [Double]
    public var confidence: Double?
    public var estimates: [Double]
    public var rawKey: String?
    public var rawScale: String?
    public var keyStrength: Double?
    public var params: [String: String]
    public var version: String
    public var errors: [String]
    public var detectedAt: Date

    public init(trimRevision: Int, rawBpm: Double?, roundedBpm: Double?, ticksSec: [Double], confidence: Double?, estimates: [Double], rawKey: String?, rawScale: String?, keyStrength: Double?, params: [String: String], version: String, errors: [String], detectedAt: Date) {
        self.trimRevision = trimRevision; self.rawBpm = rawBpm; self.roundedBpm = roundedBpm; self.ticksSec = ticksSec; self.confidence = confidence; self.estimates = estimates; self.rawKey = rawKey; self.rawScale = rawScale; self.keyStrength = keyStrength; self.params = params; self.version = version; self.errors = errors; self.detectedAt = detectedAt
    }
}

public struct TimingConfirmation: Codable, Hashable, Sendable {
    public var trimRevision: Int
    public var bpm: Double // quarter-note BPM, always .0 or .5
    public var beatOriginUs: Int64 // clip-local
    public var meter: Meter
    public var meterConfirmed: Bool
    public var barAnchorUs: Int64?
    public var key: KeySignature
    public var confirmedAt: Date

    public init(trimRevision: Int, bpm: Double, beatOriginUs: Int64, meter: Meter, meterConfirmed: Bool,
                barAnchorUs: Int64?, key: KeySignature, confirmedAt: Date = Date()) {
        self.trimRevision = trimRevision; self.bpm = bpm; self.beatOriginUs = beatOriginUs; self.meter = meter
        self.meterConfirmed = meterConfirmed; self.barAnchorUs = barAnchorUs; self.key = key
        self.confirmedAt = confirmedAt
    }

    public var grid: BeatGrid { BeatGrid(bpm: bpm, beatOriginUs: beatOriginUs, meter: meter, barAnchorUs: barAnchorUs) }
}

public enum StemLevel: String, Codable, Sendable { case normal, weak, silent }

public struct StemAsset: Codable, Hashable, Sendable {
    public var kind: StemKind
    public var relativePath: String // relative to the app data root
    public var bytes: Int64
    public var decodedFrames: Int64
    public var peakDbfs: Double?
    public var level: StemLevel
    /// Lossless audio of this stem just before the selection (see SeparationRecord.leadInUs).
    public var leadInPath: String?

    public init(kind: StemKind, relativePath: String, bytes: Int64, decodedFrames: Int64, peakDbfs: Double?, level: StemLevel) {
        self.kind = kind; self.relativePath = relativePath; self.bytes = bytes; self.decodedFrames = decodedFrames; self.peakDbfs = peakDbfs; self.level = level
    }
}

public struct SeparationRecord: Codable, Hashable, Sendable {
    public var trimRevision: Int
    public var stems: [StemAsset]
    public var sharedGainDb: Double
    public var encoder: String
    public var logicVersion: String?
    public var frames: Int64
    public var createdAt: Date
    public var candidatesDeleted: Bool
    /// The separator also ran on this much audio before the selection, so a chord struck just
    /// before the clip start (an anticipated first chord) is separated and transcribed whole.
    /// The stems themselves cover exactly the selection; the lead-in is kept apart.
    public var leadInUs: Int64?
    /// Several selected stems mixed into one (with a mixed lead-in), and which ones.
    public var mix: StemAsset?
    public var mixKinds: [StemKind]?

    public func stem(_ kind: StemKind) -> StemAsset? { stems.first { $0.kind == kind } }

    public init(trimRevision: Int, stems: [StemAsset], sharedGainDb: Double, encoder: String, logicVersion: String?, frames: Int64, createdAt: Date, candidatesDeleted: Bool) {
        self.trimRevision = trimRevision; self.stems = stems; self.sharedGainDb = sharedGainDb; self.encoder = encoder; self.logicVersion = logicVersion; self.frames = frames; self.createdAt = createdAt; self.candidatesDeleted = candidatesDeleted
    }
}

public enum AnalysisState: String, Codable, Sendable {
    case draft, detecting, awaitingConfirmation, separating, awaitingStem
    case transcribing, editingMidi, harmonizing, ready

    public var display: String {
        switch self {
        case .draft: "选区"
        case .detecting: "检测速度调性"
        case .awaitingConfirmation: "待确认速度调性"
        case .separating: "拆轨中"
        case .awaitingStem: "待选分轨"
        case .transcribing: "转录中"
        case .editingMidi: "转录完成"
        case .harmonizing: "和声分析中"
        case .ready: "完成"
        }
    }
}

public struct AnalysisItem: Record {
    public static let kind = "analysis"
    public var id: UUID
    public var songId: UUID
    public var title: String
    public var state: AnalysisState
    public var source: SourceRef
    public var trimStartUs: Int64
    public var trimEndUs: Int64
    public var trimRevision: Int
    public var detection: Detection?
    /// Whole-song beats and bar lines for snapping the selection; adjusting it never touches the selection.
    public var songGrid: SongGrid?
    public var timing: TimingConfirmation?
    public var timingRevision: Int
    public var separation: SeparationRecord?
    public var selectedStem: StemKind?
    /// More harmony stems transcribed together with `selectedStem` (mixed into one track first),
    /// e.g. a thin piano plus the "other" track carrying the pads.
    public var extraStems: [StemKind]?
    public var confirmedMidiRevision: Int?
    public var harmonyRevision: Int?
    public var tags: [String]
    public var skeletonTags: [String]
    public var sortIndex: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), songId: UUID, title: String, source: SourceRef, trimStartUs: Int64, trimEndUs: Int64) {
        self.id = id; self.songId = songId; self.title = title; state = .draft; self.source = source
        self.trimStartUs = trimStartUs; self.trimEndUs = trimEndUs; trimRevision = 1
        timingRevision = 0; tags = []; skeletonTags = []; sortIndex = Date().timeIntervalSince1970
        createdAt = Date(); updatedAt = Date()
    }

    public var ownerId: UUID? { songId }
    public var sortKey: Double { sortIndex }
    public var durationUs: Int64 { trimEndUs - trimStartUs }
    public var isHarmonic: Bool { selectedStem?.isHarmonic ?? false }

    /// The stems that go into transcription, in a fixed order.
    public var selectedStems: [StemKind] {
        guard let s = selectedStem else { return [] }
        let all = Set([s] + (extraStems ?? []))
        return StemKind.allCases.filter { all.contains($0) }
    }

    /// "钢琴" or "钢琴 + 其他".
    public var stemLabel: String { selectedStems.map(\.displayName).joined(separator: " + ") }

    /// The audio transcribed and auditioned as "the stem": the mix of the selected stems when
    /// there are several, else the one stem.
    public var transcriptionStem: StemAsset? {
        guard let sep = separation, let primary = selectedStem else { return nil }
        if selectedStems.count > 1, let m = sep.mix, sep.mixKinds == selectedStems { return m }
        return sep.stem(primary)
    }

    /// MuScriptor's instrument set: a mix of stems is transcribed as "other" (all instruments).
    public var transcriberStem: String { selectedStems.count > 1 ? StemKind.other.rawValue : (selectedStem ?? .piano).rawValue }

    /// Confirmation is only valid for the selection it was made on.
    public var hasValidTiming: Bool { timing?.trimRevision == trimRevision }
}

// MARK: - MIDI

public enum VelocitySource: String, Codable, Sendable { case `default`, edited }

public struct MidiNote: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var pitch: Int
    public var velocity: Int
    public var velocitySource: VelocitySource
    public var startUs: Int64 // clip-local
    public var endUs: Int64
    public var instrument: String
    /// Set when the note came from the transcriber, so edits can be marked.
    public var transcribedIndex: Int?
    public var edited: Bool

    public init(id: UUID = UUID(), pitch: Int, velocity: Int = 100, velocitySource: VelocitySource = .default,
                startUs: Int64, endUs: Int64, instrument: String = "", transcribedIndex: Int? = nil, edited: Bool = false) {
        self.id = id; self.pitch = pitch; self.velocity = velocity; self.velocitySource = velocitySource
        self.startUs = startUs; self.endUs = endUs; self.instrument = instrument
        self.transcribedIndex = transcribedIndex; self.edited = edited
    }

    public var durationUs: Int64 { endUs - startUs }
}

public enum MidiRevisionStatus: String, Codable, Sendable { case draft, confirmed }

public struct MidiRevision: Record {
    public static let kind = "midi"
    public var id: UUID
    public var analysisId: UUID
    public var revision: Int
    public var status: MidiRevisionStatus
    public var parentRevision: Int?
    public var stem: StemKind
    public var transcriber: [String: String]
    public var notes: [MidiNote]
    public var midiFile: String? // relative path of the confirmed .mid
    public var createdAt: Date
    public var confirmedAt: Date?

    public init(analysisId: UUID, revision: Int, status: MidiRevisionStatus, parentRevision: Int?, stem: StemKind,
                transcriber: [String: String], notes: [MidiNote]) {
        id = UUID(); self.analysisId = analysisId; self.revision = revision; self.status = status
        self.parentRevision = parentRevision; self.stem = stem; self.transcriber = transcriber; self.notes = notes
        createdAt = Date()
    }

    public var ownerId: UUID? { analysisId }
    public var sortKey: Double { Double(revision) }
}

// MARK: - Harmony

public enum NoteRole: String, Codable, Sendable {
    case chordTone, possibleTension, possiblePassing, possibleMelody

    public var display: String {
        switch self {
        case .chordTone: "和弦音"
        case .possibleTension: "可能延伸音"
        case .possiblePassing: "可能经过音"
        case .possibleMelody: "可能旋律"
        }
    }
}

public enum Texture: String, Codable, Sendable {
    case block, broken, mixed
    public var display: String {
        switch self { case .block: "柱式"; case .broken: "分解"; case .mixed: "混合" }
    }
}

public enum NamingSource: String, Codable, Sendable { case musicpy, template, user, agent }

public struct ChordCandidate: Codable, Hashable, Sendable {
    public var symbol: String
    public var source: NamingSource
    public var score: Double?
    public var raw: String?

    public init(symbol: String, source: NamingSource, score: Double?, raw: String?) {
        self.symbol = symbol; self.source = source; self.score = score; self.raw = raw
    }
}

public struct DegreeLabel: Codable, Hashable, Sendable {
    public var degreeIndex: Int // 1...7
    public var accidental: Int // -1 flat, 0, +1 sharp (relative to the major scale of the tonic)
    public var quality: String // chord suffix as written
    public var minorThird: Bool
    public var bassDegree: String?
    public var display: String

    public init(degreeIndex: Int, accidental: Int, quality: String, minorThird: Bool, bassDegree: String?, display: String) {
        self.degreeIndex = degreeIndex; self.accidental = accidental; self.quality = quality; self.minorThird = minorThird; self.bassDegree = bassDegree; self.display = display
    }
}

public struct ChordEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: String // "chord-01" style, stable within a harmony revision
    public var order: Int
    public var startUs: Int64
    public var endUs: Int64
    public var noteIds: [UUID]
    public var noteRoles: [UUID: NoteRole]
    public var texture: Texture
    public var excludedNoteIds: [UUID]
    public var namingPitches: [Int]
    public var candidates: [ChordCandidate]
    public var symbol: String? // nil = 未确定
    public var namingSource: NamingSource?
    public var manualOverride: Bool
    public var degree: DegreeLabel?
    public var bassPitch: Int?

    public init(id: String, order: Int, startUs: Int64, endUs: Int64, noteIds: [UUID], noteRoles: [UUID: NoteRole],
                texture: Texture, excludedNoteIds: [UUID], namingPitches: [Int], candidates: [ChordCandidate],
                symbol: String?, namingSource: NamingSource?, manualOverride: Bool, degree: DegreeLabel?, bassPitch: Int?) {
        self.id = id; self.order = order; self.startUs = startUs; self.endUs = endUs; self.noteIds = noteIds
        self.noteRoles = noteRoles; self.texture = texture; self.excludedNoteIds = excludedNoteIds
        self.namingPitches = namingPitches; self.candidates = candidates; self.symbol = symbol
        self.namingSource = namingSource; self.manualOverride = manualOverride; self.degree = degree; self.bassPitch = bassPitch
    }

    public var durationUs: Int64 { endUs - startUs }
}

public struct HarmonyRevision: Record {
    public static let kind = "harmony"
    public var id: UUID
    public var analysisId: UUID
    public var revision: Int
    public var midiRevision: Int
    public var timingRevision: Int
    public var key: KeySignature
    public var events: [ChordEvent]
    public var params: [String: String]
    public var namerVersion: String
    public var needsReview: [String] // e.g. "timing changed"
    /// Present when the revision was produced by model-driven analysis.
    public var auto: AutoHarmony?
    public var createdAt: Date

    public init(analysisId: UUID, revision: Int, midiRevision: Int, timingRevision: Int, key: KeySignature,
                events: [ChordEvent], params: [String: String], namerVersion: String) {
        id = UUID(); self.analysisId = analysisId; self.revision = revision; self.midiRevision = midiRevision
        self.timingRevision = timingRevision; self.key = key; self.events = events; self.params = params
        self.namerVersion = namerVersion; needsReview = []; createdAt = Date()
    }

    public var ownerId: UUID? { analysisId }
    public var sortKey: Double { Double(revision) }
}

public struct SkeletonRelation: Codable, Hashable, Sendable {
    public var eventId: String
    public var kind: String // passing / connecting / substitute / other
    public var targetEventId: String?
    public var reason: String

    public init(eventId: String, kind: String, targetEventId: String?, reason: String) {
        self.eventId = eventId; self.kind = kind; self.targetEventId = targetEventId; self.reason = reason
    }
}

public struct SkeletonAlternative: Codable, Hashable, Sendable {
    public var backboneEventIds: [String]
    public var reason: String

    public init(backboneEventIds: [String], reason: String) {
        self.backboneEventIds = backboneEventIds; self.reason = reason
    }
}

public enum JobStatus: String, Codable, Sendable { case queued, running, succeeded, failed, cancelled, interrupted }

/// The model's view of the key, checked against the one the user set.
public struct KeySuggestion: Codable, Hashable, Sendable {
    public var tonic: String
    public var mode: String // major / minor (how the app stores it)
    public var modeName: String // e.g. "F♯ 小调（弗里几亚色彩）"
    public var agreesWithCurrent: Bool
    public var reason: String
    public init(tonic: String, mode: String, modeName: String, agreesWithCurrent: Bool, reason: String) {
        self.tonic = tonic; self.mode = mode; self.modeName = modeName; self.agreesWithCurrent = agreesWithCurrent; self.reason = reason
    }
    public var key: KeySignature? {
        Pitch.parsePitchClass(tonic).map { KeySignature(tonic: $0, tonicName: Pitch.normalizeName(tonic), mode: mode == "minor" ? .minor : .major) }
    }
}

public struct SkeletonVoicing: Codable, Hashable, Sendable {
    public var eventId: String
    public var description: String
    public init(eventId: String, description: String) { self.eventId = eventId; self.description = description }
}

public struct Skeleton: Record {
    public static let kind = "skeleton"
    public var id: UUID
    public var analysisId: UUID
    public var harmonyRevision: Int
    public var provider: String
    public var model: String
    public var status: JobStatus
    public var backboneEventIds: [String]
    public var relations: [SkeletonRelation]
    public var alternatives: [SkeletonAlternative]
    public var explanation: String
    public var summary: String?
    public var numberPattern: String?
    public var keySuggestion: KeySuggestion?
    public var voicings: [SkeletonVoicing]?
    public var keyUsed: String?
    public var unstructured: Bool
    public var error: String?
    public var createdAt: Date

    public init(analysisId: UUID, harmonyRevision: Int, provider: String, model: String) {
        id = UUID(); self.analysisId = analysisId; self.harmonyRevision = harmonyRevision
        self.provider = provider; self.model = model; status = .running; backboneEventIds = []
        relations = []; alternatives = []; explanation = ""; unstructured = false; createdAt = Date()
    }

    public var ownerId: UUID? { analysisId }
    public var sortKey: Double { createdAt.timeIntervalSince1970 }
}

public struct NoteDocument: Record {
    public static let kind = "notedoc"
    public var id: UUID // equals analysisId
    public var text: String
    public var revision: Int
    public var updatedAt: Date

    public init(analysisId: UUID, text: String = "") { id = analysisId; self.text = text; revision = 0; updatedAt = Date() }
    public var ownerId: UUID? { id }
    public var sortKey: Double { 0 }
}

// MARK: - Chat

public enum MentionKind: String, Codable, Sendable { case song, analysis, conversation }

public struct Mention: Codable, Hashable, Sendable {
    public var kind: MentionKind
    public var objectId: UUID
    public var title: String
    /// Revisions of the referenced data at send time (midi/harmony/skeleton/conversation).
    public var revisions: [String: Int]
    public var scope: String // "wholeConversation" for conversations, "song" / "analysis" otherwise
    public var complete: Bool

    public init(kind: MentionKind, objectId: UUID, title: String, revisions: [String: Int], scope: String, complete: Bool) {
        self.kind = kind; self.objectId = objectId; self.title = title; self.revisions = revisions; self.scope = scope; self.complete = complete
    }
}

public enum MessageRole: String, Codable, Sendable { case user, assistant, system }
public enum MessageStatus: String, Codable, Sendable { case complete, streaming, incomplete, failed }

public struct Message: Record {
    public static let kind = "message"
    public var id: UUID
    public var conversationId: UUID
    public var sequence: Int
    public var role: MessageRole
    public var content: String
    public var status: MessageStatus
    public var mentions: [Mention]
    public var provider: String?
    public var model: String?
    public var requestId: UUID?
    public var usageTokens: Int?
    public var error: String?
    public var createdAt: Date

    public init(conversationId: UUID, sequence: Int, role: MessageRole, content: String,
                status: MessageStatus = .complete, mentions: [Mention] = []) {
        id = UUID(); self.conversationId = conversationId; self.sequence = sequence; self.role = role
        self.content = content; self.status = status; self.mentions = mentions; createdAt = Date()
    }

    public var ownerId: UUID? { conversationId }
    public var sortKey: Double { Double(sequence) }
}

public struct ProviderBinding: Codable, Hashable, Sendable {
    public var provider: String // "codex" / "claude"
    public var backendSessionId: String?
    /// Last local message sequence the backend session has seen.
    public var syncedThroughSequence: Int

    public init(provider: String, backendSessionId: String?, syncedThroughSequence: Int) {
        self.provider = provider; self.backendSessionId = backendSessionId; self.syncedThroughSequence = syncedThroughSequence
    }
}

public struct ContextSummary: Codable, Hashable, Sendable {
    public var throughSequence: Int
    public var summary: String
    public var createdAt: Date

    public init(throughSequence: Int, summary: String, createdAt: Date) {
        self.throughSequence = throughSequence; self.summary = summary; self.createdAt = createdAt
    }
}

public struct Conversation: Record {
    public static let kind = "conversation"
    public var id: UUID
    public var title: String
    public var provider: String
    public var model: String?
    public var effort: String?
    public var bindings: [ProviderBinding]
    public var summaries: [ContextSummary]
    public var revision: Int
    public var lastTokens: Int?
    public var contextWindow: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(title: String = "新会话", provider: String) {
        id = UUID(); self.title = title; self.provider = provider; bindings = []; summaries = []
        revision = 0; createdAt = Date(); updatedAt = Date()
    }

    public var ownerId: UUID? { nil }
    public var sortKey: Double { updatedAt.timeIntervalSince1970 }
}

public struct Highlight: Record {
    public static let kind = "highlight"
    public var id: UUID
    public var conversationId: UUID
    public var messageId: UUID
    public var rangeStart: Int
    public var rangeLength: Int
    public var quotedText: String
    public var bookmarked: Bool
    public var label: String
    public var createdAt: Date

    public init(conversationId: UUID, messageId: UUID, rangeStart: Int, rangeLength: Int, quotedText: String, bookmarked: Bool) {
        id = UUID(); self.conversationId = conversationId; self.messageId = messageId
        self.rangeStart = rangeStart; self.rangeLength = rangeLength; self.quotedText = quotedText
        self.bookmarked = bookmarked; label = ""; createdAt = Date()
    }

    public var ownerId: UUID? { conversationId }
    public var sortKey: Double { createdAt.timeIntervalSince1970 }
}

public struct ReferenceMaterial: Record {
    public static let kind = "reference"
    public var id: UUID
    public var title: String
    public var author: String
    public var sourceURL: String
    public var section: String
    public var content: String // empty = 待读取
    public var retrievedAt: Date?
    public var version: String

    public init(title: String, author: String, sourceURL: String, section: String, content: String = "") {
        id = UUID(); self.title = title; self.author = author; self.sourceURL = sourceURL
        self.section = section; self.content = content; version = "1"
    }

    public var ownerId: UUID? { nil }
    public var sortKey: Double { 0 }
    public var isRead: Bool { !content.isEmpty }
}

/// A playable, ordered set of chords the user explicitly collected.
public struct CollectionItem: Codable, Hashable, Sendable {
    public var analysisId: UUID
    public var eventId: String
    public var harmonyRevision: Int
    public var symbol: String
    public var notes: [BlockNote]

    public init(analysisId: UUID, eventId: String, harmonyRevision: Int, symbol: String, notes: [BlockNote]) {
        self.analysisId = analysisId; self.eventId = eventId; self.harmonyRevision = harmonyRevision; self.symbol = symbol; self.notes = notes
    }
}

public struct LearningCollection: Record {
    public static let kind = "collection"
    public var id: UUID
    public var title: String
    public var items: [CollectionItem]
    public var createdAt: Date

    public init(title: String) { id = UUID(); self.title = title; items = []; createdAt = Date() }
    public var ownerId: UUID? { nil }
    public var sortKey: Double { createdAt.timeIntervalSince1970 }
}

// MARK: - Playground

/// A note inside a chord block, relative to the block start, in quarter beats.
public struct BlockNote: Codable, Hashable, Sendable {
    public var pitch: Int
    public var velocity: Int
    public var startQ: Double
    public var durationQ: Double
    /// Identity of the source note, so shared sustains are not re-triggered.
    public var sourceNoteId: UUID?

    public init(pitch: Int, velocity: Int, startQ: Double, durationQ: Double, sourceNoteId: UUID?) {
        self.pitch = pitch; self.velocity = velocity; self.startQ = startQ; self.durationQ = durationQ; self.sourceNoteId = sourceNoteId
    }
}

public enum VoicingMode: String, Codable, Sendable { case original, standard }

public struct BlockSource: Codable, Hashable, Sendable {
    public var kind: String // chord / progression / skeleton / collection / manual
    public var analysisId: UUID?
    public var eventId: String?
    public var harmonyRevision: Int?
    public var sourceKey: KeySignature?
    public var sourceBpm: Double?
    public var label: String

    public init(kind: String, analysisId: UUID? = nil, eventId: String? = nil, harmonyRevision: Int? = nil, sourceKey: KeySignature? = nil, sourceBpm: Double? = nil, label: String) {
        self.kind = kind; self.analysisId = analysisId; self.eventId = eventId; self.harmonyRevision = harmonyRevision; self.sourceKey = sourceKey; self.sourceBpm = sourceBpm; self.label = label
    }
}

public struct ChordBlock: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var startQ: Double // within the section
    public var durationQ: Double
    public var symbol: String
    public var voicingMode: VoicingMode
    public var originalNotes: [BlockNote] // at original duration, transposed
    public var originalDurationQ: Double
    public var transposeSemitones: Int
    public var octaveShift: Int
    public var source: BlockSource
    public var simplified: Bool

    public init(id: UUID = UUID(), startQ: Double, durationQ: Double, symbol: String, voicingMode: VoicingMode,
                originalNotes: [BlockNote], originalDurationQ: Double, transposeSemitones: Int = 0,
                source: BlockSource, simplified: Bool = false) {
        self.id = id; self.startQ = startQ; self.durationQ = durationQ; self.symbol = symbol
        self.voicingMode = voicingMode; self.originalNotes = originalNotes; self.originalDurationQ = originalDurationQ
        self.transposeSemitones = transposeSemitones; octaveShift = 0; self.source = source; self.simplified = simplified
    }

    public var endQ: Double { startQ + durationQ }
}

public struct PlaygroundSection: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var barCount: Int
    public var blocks: [ChordBlock]

    public init(name: String, barCount: Int) { id = UUID(); self.name = name; self.barCount = barCount; blocks = [] }
}

public struct PlaygroundProject: Record, Hashable {
    public static let kind = "playground"
    public var id: UUID
    public var title: String
    public var key: KeySignature
    public var bpm: Double
    public var meter: Meter
    public var sections: [PlaygroundSection]
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(title: String, key: KeySignature, bpm: Double, meter: Meter) {
        id = UUID(); self.title = title; self.key = key; self.bpm = bpm; self.meter = meter
        sections = [PlaygroundSection(name: "Verse", barCount: 8)]; revision = 0; createdAt = Date(); updatedAt = Date()
    }

    public var ownerId: UUID? { nil }
    public var sortKey: Double { updatedAt.timeIntervalSince1970 }
}

// MARK: - Jobs

public enum JobType: String, Codable, Sendable { case detect, separate, transcribe, harmony, skeleton }

public struct Job: Record {
    public static let kind = "job"
    public var id: UUID
    public var type: JobType
    public var analysisId: UUID
    public var inputRevision: Int
    public var status: JobStatus
    public var stage: String
    public var completedUnits: Int
    public var totalUnits: Int?
    public var attempt: Int
    public var directory: String // relative job dir
    public var errorCode: String?
    public var errorMessage: String?
    public var startedAt: Date
    public var heartbeat: Date

    public init(type: JobType, analysisId: UUID, inputRevision: Int, directory: String) {
        id = UUID(); self.type = type; self.analysisId = analysisId; self.inputRevision = inputRevision
        status = .running; stage = ""; completedUnits = 0; attempt = 1; self.directory = directory
        startedAt = Date(); heartbeat = Date()
    }

    public var ownerId: UUID? { analysisId }
    public var sortKey: Double { startedAt.timeIntervalSince1970 }
}

public extension HarmonyRevision {
    /// Bar line used for grouping (the user's, or the estimate when none was set).
    var barAnchorUs: Int64? { params["barAnchorUs"].flatMap(Int64.init) }
    var barAnchorEstimated: Bool { params["barAnchorEstimated"] == "1" }

    /// "第 2 小节第 1 拍" style position on the grid used for grouping.
    func position(of us: Int64, grid: BeatGrid) -> String {
        var g = grid
        if g.barAnchorUs == nil { g.barAnchorUs = barAnchorUs }
        let perBar = g.meter.quarterBeatsPerBar
        let q = g.q(atUs: us) - g.barAnchorQ
        let snapped = (q * 2).rounded() / 2
        var bar = Int(floor(snapped / perBar))
        var beat = snapped - Double(bar) * perBar + 1
        if beat > perBar + 0.5 { bar += 1; beat -= perBar }
        let beatText = beat == beat.rounded() ? String(Int(beat)) : String(format: "%.1f", beat)
        return "第 \(bar + 1) 小节第 \(beatText) 拍"
    }
}
