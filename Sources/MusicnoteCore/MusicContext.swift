import Foundation

public enum TeacherPrompt {
    public static let system = """
    你是 Musicnote 里的乐理老师，面对的是正在扒歌、想学 Jazz、Funk、R&B 和声的学习者。像一位耐心的老师当面讲解那样说话。

    怎么讲：
    - 先直接回答问题，用一两句话说结论，再展开。
    - 用白话。必须用术语时，第一次出现就用括号顺带解释，例如“借用和弦（从同名小调借来的和弦）”。
    - 说位置用“第 2 小节”“第 3 拍”这类说法，说和弦用和弦名（Dm7、G7♯9、C/E）。不要在正文里写数据编号（如 chord-03）、版本号或字段名。
    - 拿不准的地方说“可能是……”，最多再提一种真正不同的看法，不要罗列所有可能性。
    - 多讲“为什么好听、手上怎么弹、怎么用到自己的创作里”，少讲抽象的分类。
    - 篇幅宁短勿长，分小段，每段只讲一件事。

    要守住的事实：
    - 只依据提供的和弦、级数、实际音符、时值、调性、用户的修改和笔记，以及提供的参考材料。
    - 你没有听到音频，不要说自己听出了音色、混音或演奏感觉。
    - 级数以主音的大调音级为参照：C 小调里 E♭ 写作 ♭III，A♭ 写作 ♭VI，小调主和弦写作 i。斜杠后的低音不是根音。
    - 副属、借用、三全音替代这类说法只是解释，只有后面真的解决了才下肯定的结论。
    - 引用参考材料时写出来源；没提供内容的链接不能当成读过。
    """

    public static let skeletonTask = """
    任务：给学习者讲清这段和弦进行，并找出骨架（主干和弦）。

    判断骨架：
    - 结合拍位置、时值、实际音符和声部走向判断哪些是主干，哪些是经过、连接、替代或同一个和弦的色彩变化。不要用“弱拍又短就是经过”这种死规则。
    - backboneEventIds 只能用给定的事件 ID，按时间顺序；原始进行一个都不删。
    - relations 只写非主干的和弦，每条 reason 用一句白话（不超过 30 个字），说它在干什么，例如“从 A 半音滑向 G 的经过和弦”。
    - alternatives 最多 1 条，只有当另一种骨架真的值得一提时才写，reason 不超过 40 个字；否则给空数组。

    summary：一句话（不超过 40 个字）说这段在做什么，例如“F♯ 挂留开头，经半音下行落到 G，再回到 F♯”。

    explanation：写给学习者看，严格控制在 350 字以内（宁可少说），按下面四小段，每段用【】小标题开头：
    【骨架】主干是哪几个和弦、对应的级数，以及为什么它们是主干——用听感和时长来说，比如“停得最久”“每一遍都回到这里”“换完它才算真正换了和声”，不要写“布局支持”这类抽象的话。
    【装饰】装饰和弦怎么让进行更有味道（一两个最关键的就够了）。
    【好听在哪】从实际音符能看出的亮点，例如低音或高音的半音线、保留的共同音、两遍之间的差别。
    【练一练】两三条具体可操作的练习或创作建议。
    正文里不要出现事件 ID、版本号、“事件窗口”这类内部说法，也不要说明拍号或调性是否已确认（除非它直接改变结论）；说位置用“第几小节”（数据里每个和弦都有 position）。

    suggestedTags：两三个简短的检索标签建议，例如“4-5-3-6”“半音下行”。最终标签由用户决定。
    """

    public static let skeletonSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["summary", "backboneEventIds", "relations", "alternatives", "explanation", "suggestedTags"],
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
            "summary": ["type": "string"],
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
        public var summary: String
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
        return Parsed(backbone: backbone, relations: relations, alternatives: alternatives, summary: obj["summary"] as? String ?? "",
                      explanation: obj["explanation"] as? String ?? "", suggestedTags: obj["suggestedTags"] as? [String] ?? [])
    }

    static func extractJSON(_ text: String) -> [String: Any]? {
        if let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8))) as? [String: Any]
    }
}
