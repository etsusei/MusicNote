import Foundation

public enum TeacherPrompt {
    public static let system = """
    你是 Musicnote 里的音乐学习助手，也是一位乐理老师，重点是 Jazz、Funk、R&B 的实际听感、和声与创作。

    工作方式：
    - 只依据本次提供的结构化音乐数据（和弦、级数、实际音符、时值、调性、用户修订与笔记）和已提供的参考材料来解释。
    - 明确区分三类内容：【事实】数据里确实有的；【解释】乐理上的候选解释；【练习】可以怎么练或怎么用到创作里。
    - 你没有听到音频。不要声称判断了音色、混音或演奏感觉；需要时说明缺少什么信息。
    - 级数记法：一律以主音的大调音级为参照。C 小调里 E♭ 写作 ♭III、A♭ 写作 ♭VI，小调主和弦写作 i。斜杠低音不替代根音。
    - 副属、借用、三全音替代等是解释层的候选，不要当成已确认的基本级数。
    - 不确定时给出多种解释并说明各自的依据，不编造唯一正确答案。
    - 引用参考材料时写出来源标题与章节；没有提供内容的链接不要当成读过。
    - 引用具体和弦时尽量写出事件 ID（如 chord-03），便于回到原数据核对。
    - 用简洁的中文回答，和弦符号用常见写法（Dm7、G7♯9、C/E）。
    """

    public static let skeletonTask = """
    任务：解释这段完整和弦进行，并给出可能的骨架（主干）。
    - 结合乐理、时值、拍位置和实际音符排列判断哪些和弦是主干，哪些是经过、连接或替代；不要用“弱拍且短就是经过”这种固定规则。
    - 骨架只能引用给定事件 ID，按时间顺序排列。原始进行一个都不能删。
    - 有歧义时在 alternatives 里给出其他骨架及理由；不必强行套常见模板。
    - explanation 用中文写给学习者看，包含事实、解释与练习建议。
    - 最终的检索标签由用户自己填写，你只给建议。
    """

    public static let skeletonSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["backboneEventIds", "relations", "alternatives", "explanation", "suggestedTags"],
        "properties": [
            "backboneEventIds": ["type": "array", "items": ["type": "string"]],
            "relations": ["type": "array", "items": [
                "type": "object", "additionalProperties": false,
                "required": ["eventId", "kind", "targetEventId", "reason"],
                "properties": [
                    "eventId": ["type": "string"],
                    "kind": ["type": "string", "enum": ["passing", "connecting", "substitute", "other"]],
                    "targetEventId": ["type": ["string", "null"]],
                    "reason": ["type": "string"],
                ],
            ]],
            "alternatives": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["backboneEventIds", "reason"],
                "properties": ["backboneEventIds": ["type": "array", "items": ["type": "string"]], "reason": ["type": "string"]],
            ]],
            "explanation": ["type": "string"],
            "suggestedTags": ["type": "array", "items": ["type": "string"]],
        ],
    ]
}

/// Builds the versioned snapshots sent to the model. Fields are a product contract,
/// not any provider's API.
public struct SnapshotBuilder {
    public let store: Store
    public init(store: Store) { self.store = store }

    public func latestHarmony(_ analysisId: UUID) -> HarmonyRevision? {
        store.all(HarmonyRevision.self, owner: analysisId).max { $0.revision < $1.revision }
    }

    public func confirmedMidi(_ item: AnalysisItem) -> MidiRevision? {
        guard let r = item.confirmedMidiRevision else { return nil }
        return store.all(MidiRevision.self, owner: item.id).first { $0.revision == r }
    }

    public func latestSkeleton(_ analysisId: UUID) -> Skeleton? {
        store.all(Skeleton.self, owner: analysisId).filter { $0.status == .succeeded }.max { $0.createdAt < $1.createdAt }
    }

    public func analysisSnapshot(_ item: AnalysisItem, includeNotes: Bool = true) -> [String: Any] {
        let song = store.fetch(Song.self, id: item.songId)
        var o: [String: Any] = [
            "schemaVersion": 1, "analysisId": item.id.uuidString, "title": item.title,
            "song": ["title": song?.title ?? "", "artist": song?.artist ?? ""],
            "segment": ["startSec": item.trimStartUs.seconds, "endSec": item.trimEndUs.seconds],
            "stem": item.selectedStem?.displayName ?? "未选", "state": item.state.display,
        ]
        let midi = confirmedMidi(item)
        let harmony = latestHarmony(item.id)
        o["inputRevision"] = ["midi": item.confirmedMidiRevision ?? 0, "harmony": harmony?.revision ?? 0, "timing": item.timingRevision]
        if let t = item.timing {
            o["key"] = ["tonic": t.key.tonicName, "mode": t.key.mode.rawValue, "confirmed": true]
            o["tempo"] = ["bpm": t.bpm, "quarterNoteBased": true]
            o["meter"] = ["numerator": t.meter.numerator, "denominator": t.meter.denominator, "confirmed": t.meterConfirmed]
        }
        if let harmony, let t = item.timing {
            let grid = t.grid
            let byId = Dictionary(uniqueKeysWithValues: (midi?.notes ?? []).map { ($0.id, $0) })
            o["events"] = harmony.events.map { e -> [String: Any] in
                let q0 = grid.q(atUs: e.startUs), q1 = grid.q(atUs: e.endUs)
                let members = e.noteIds.compactMap { byId[$0] }.sorted { ($0.startUs, $0.pitch) < ($1.startUs, $1.pitch) }
                var ev: [String: Any] = [
                    "id": e.id, "symbol": e.symbol ?? "未确定", "degree": e.degree?.display ?? "",
                    "startUs": e.startUs, "endUs": e.endUs,
                    "startQuarterBeats": (q0 * 100).rounded() / 100, "durationQuarterBeats": ((q1 - q0) * 100).rounded() / 100,
                    "texture": e.texture.display, "namingSource": e.manualOverride ? "user-confirmed" : (e.namingSource?.rawValue ?? "none"),
                    "voicing": e.namingPitches.map { Pitch.noteName($0, flats: Pitch.prefersFlats(t.key)) },
                ]
                if let l = BeatGrid.durationLabel(quarterBeats: q1 - q0) { ev["durationLabel"] = l }
                ev["position"] = harmony.position(of: e.startUs, grid: grid)
                // Actual notes in time order, compact: name@beat(+len)
                ev["notes"] = members.prefix(48).map { n -> String in
                    let role = e.noteRoles[n.id].map { $0 == .chordTone ? "" : "[" + $0.display + "]" } ?? ""
                    return String(format: "%@@%.2f+%.2f%@", Pitch.noteName(n.pitch, flats: Pitch.prefersFlats(t.key)),
                                  grid.q(atUs: n.startUs) - q0, Double(n.durationUs) / grid.beatUs, role)
                }
                if !e.excludedNoteIds.isEmpty { ev["userExcludedNotes"] = e.excludedNoteIds.count }
                return ev
            }
        }
        if let h = harmony, let r = h.repetition {
            o["repetition"] = ["periodBeats": r.beats, "count": r.count,
                               "note": "分组时检测到这段每 \(r.beats) 拍重复一次，各遍使用相同切分；和弦名按每遍实际音符命名，差异来自实际演奏或转录。",
                               "eventsByRepeat": h.eventsByRepeat.map { $0.map(\.id) }]
        }
        if let s = latestSkeleton(item.id) {
            o["skeleton"] = ["backboneEventIds": s.backboneEventIds, "explanation": s.explanation, "fromHarmonyRevision": s.harmonyRevision]
        }
        o["userSkeletonTags"] = item.skeletonTags
        o["userTags"] = item.tags
        if includeNotes, let doc = store.fetch(NoteDocument.self, id: item.id), !doc.text.isEmpty { o["userNotes"] = doc.text }
        return o
    }

    public func songSnapshot(_ song: Song) -> [String: Any] {
        let items = store.all(AnalysisItem.self, owner: song.id)
        return [
            "schemaVersion": 1, "songId": song.id.uuidString, "title": song.title, "artist": song.artist, "album": song.album,
            "tags": song.tags,
            "analysisItems": items.map { i -> [String: Any] in
                var d: [String: Any] = ["analysisId": i.id.uuidString, "title": i.title,
                                        "segment": String(format: "%.1f–%.1fs", i.trimStartUs.seconds, i.trimEndUs.seconds),
                                        "stem": i.selectedStem?.displayName ?? "未选", "state": i.state.display,
                                        "skeletonTags": i.skeletonTags]
                if let t = i.timing { d["key"] = t.key.display; d["bpm"] = t.bpm }
                if let h = latestHarmony(i.id) { d["progression"] = h.events.map { $0.symbol ?? "?" }.joined(separator: " → ") }
                return d
            },
        ]
    }

    public static func json(_ o: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Validates the model's skeleton answer against the events it was given.
public enum SkeletonParser {
    public struct Parsed: Sendable {
        public var backbone: [String]
        public var relations: [SkeletonRelation]
        public var alternatives: [SkeletonAlternative]
        public var explanation: String
        public var suggestedTags: [String]
    }

    public static func parse(_ text: String, events: [ChordEvent]) -> Parsed? {
        guard let obj = extractJSON(text) else { return nil }
        let order = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0.order) })
        guard let backbone = obj["backboneEventIds"] as? [String], !backbone.isEmpty,
              backbone.allSatisfy({ order[$0] != nil }),
              zip(backbone, backbone.dropFirst()).allSatisfy({ order[$0]! < order[$1]! }) else { return nil }
        let relations = (obj["relations"] as? [[String: Any]] ?? []).compactMap { r -> SkeletonRelation? in
            guard let e = r["eventId"] as? String, order[e] != nil else { return nil }
            let target = r["targetEventId"] as? String
            return SkeletonRelation(eventId: e, kind: r["kind"] as? String ?? "other",
                                    targetEventId: target.flatMap { order[$0] != nil ? $0 : nil }, reason: r["reason"] as? String ?? "")
        }
        let alternatives = (obj["alternatives"] as? [[String: Any]] ?? []).compactMap { a -> SkeletonAlternative? in
            guard let ids = a["backboneEventIds"] as? [String], ids.allSatisfy({ order[$0] != nil }) else { return nil }
            return SkeletonAlternative(backboneEventIds: ids, reason: a["reason"] as? String ?? "")
        }
        return Parsed(backbone: backbone, relations: relations, alternatives: alternatives,
                      explanation: obj["explanation"] as? String ?? "", suggestedTags: obj["suggestedTags"] as? [String] ?? [])
    }

    static func extractJSON(_ text: String) -> [String: Any]? {
        if let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8))) as? [String: Any]
    }
}
