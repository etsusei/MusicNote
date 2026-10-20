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
    任务：先下结论，再讲这段和弦进行是怎么做出高级感的。读者是正在扒歌学习的人。

    第一步：核对调性。数据里有 keyCheck：用户当前设的调、音频检测的调、以及根据和弦推算的候选（含理由）。
    结合“每一遍从哪里开始、落在哪里、哪个和弦停得最久、有没有终止式”判断这段真正的主音和调式。
    keySuggestion 写你认为对的调：tonic 用音名（如 F♯），mode 只能是 major 或 minor（教会调式按最接近的大小调记，
    modeName 里再写清楚，如“F♯ 小调（带弗里几亚色彩的 ♭II）”），agreesWithCurrent 表示是否与用户当前设的调一致，
    reason 用一句白话说依据。后面所有的级数、数字和讲解都按你判断的这个调来写。

    第二步：结论。
    - numberPattern：骨架的简谱级数（如“4-5-3-6”“2-5-1-6”）。不要自己数：keyCheck.numbersByKey 里已按每个候选调
      算好了每个和弦的数字（以大调主音为 1，小调按关系大调计，所以 F♯ 小调里 F♯m 是 6、G 是 ♭7），
      从你选定的那个调里按骨架顺序抄出来，用“-”连接。有两遍就写一遍的型即可。summary 和正文里提到数字型时也用同一个写法。
    - summary：一句话结论（不超过 50 字），以“这是一首……”开头，说出数字型，像哪个常见套路（4536、4321、2516、1645……）
      就点出来；不像任何套路就说它独特在哪。

    第三步：骨架与装饰。
    - backboneEventIds 只能用给定的事件 ID，按时间顺序；原始进行一个都不删。判断时结合拍位置、时值、实际音符和声部走向，
      不要用“弱拍又短就是经过”这种死规则。
    - relations 只写非主干的和弦，reason 用一句白话（不超过 30 字）说它为什么能让听感更高级。
    - alternatives 最多 1 条，真有必要才写，reason 不超过 40 字；否则给空数组。
    - voicings：挑 2-4 个最值得学的和弦，description 用一句话说这个按法的特点和好听的原因（比如“省略三音的 sus 让开头悬着”
      “顶上叠 9 音和 13 音更亮”“上方声部 C♯→C→B 半音下行”）。界面会自动列出实际音名，description 里不要再重复音名列表。

    第四步：explanation，严格 400 字以内，按五小段，每段用【】小标题开头：
    【结论】重复数字型和一句话结论，并说调性（如果和用户设的不同，说明为什么）。
    【骨架】只弹骨架听起来是什么样，为什么这几个是主干（用“停得最久”“每遍都回到这里”这种说法）。
    【加了什么让它高级】在第几小节第几拍加了哪些经过、连接或替代和弦，各自让听感好在哪。
    【voicing】关键和弦的实际按法和特点。
    【练一练】两三条具体练习：先弹骨架，再逐步加回装饰；可以怎么用到自己的创作里。

    通用要求：用白话，术语第一次出现时用括号解释；说位置用“第几小节第几拍”（数据里每个和弦都有 position）；
    正文不出现事件 ID、版本号、“事件窗口”这类内部说法。suggestedTags 给两三个检索标签建议（如“6-♭7-6”“半音下行”），
    最终标签由用户决定。
    """

    public static let skeletonSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["keySuggestion", "numberPattern", "summary", "backboneEventIds", "relations", "alternatives", "voicings", "explanation", "suggestedTags"],
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
            "numberPattern": ["type": "string"],
            "keySuggestion": [
                "type": "object", "additionalProperties": false,
                "required": ["tonic", "mode", "modeName", "agreesWithCurrent", "reason"],
                "properties": [
                    "tonic": ["type": "string"], "mode": ["type": "string", "enum": ["major", "minor"]],
                    "modeName": ["type": "string"], "agreesWithCurrent": ["type": "boolean"], "reason": ["type": "string"],
                ],
            ],
            "voicings": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["eventId", "description"],
                "properties": ["eventId": ["type": "string"], "description": ["type": "string"]],
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
            "stem": item.selectedStem == nil ? "未选" : item.stemLabel, "state": item.state.display,
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
                let rs = BarEvidence.readingStart(e, grid: grid)
                if rs.pushed, harmony.position(of: rs.us, grid: grid) != harmony.position(of: e.startUs, grid: grid) {
                    ev["anticipates"] = harmony.position(of: rs.us, grid: grid) + "（提前一个八分音符按下）"
                }
                if let info = harmony.auto?.chordInfo[e.id] { ev["role"] = info.roleDisplay; ev["roleReason"] = info.reason }
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
        if let h = harmony, let auto = h.auto, let t = item.timing {
            o["autonomousAnalysis"] = ["summary": auto.summary, "sources": auto.sources,
                                       "toConfirm": auto.toConfirm.map { ["position": h.position(of: $0.startUs, grid: t.grid), "question": $0.question] }]
        }
        if let s = latestSkeleton(item.id) {
            o["skeleton"] = ["backboneEventIds": s.backboneEventIds, "explanation": s.explanation, "fromHarmonyRevision": s.harmonyRevision]
        }
        if let harmony {
            var check: [String: Any] = ["userSetKey": item.timing?.key.display ?? "未设"]
            if let d = item.detection, let k = d.rawKey { check["audioDetected"] = "\(k) \(d.rawScale == "minor" ? "小调" : "大调")（Essentia，基于混合音频）" }
            let cands = KeyEstimator.candidates(events: harmony.events)
            check["fromChords"] = cands.map {
                ["key": $0.key.display, "score": ($0.score * 100).rounded() / 100, "reasons": $0.reasons] as [String: Any]
            }
            // 简谱 numbers per candidate key (1 = major tonic; minor counted from the relative major),
            // precomputed so the model copies rather than counts.
            var keys = cands.map(\.key)
            if let cur = item.timing?.key, !keys.contains(cur) { keys.insert(cur, at: 0) }
            var numbers: [String: [String: String]] = [:]
            for k in keys {
                var m: [String: String] = [:]
                for e in harmony.events { if let sym = e.symbol { m[e.id] = Degrees.numberPattern([sym], key: k) } }
                numbers[k.display] = m
            }
            check["numbersByKey"] = numbers
            o["keyCheck"] = check
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
                                        "stem": i.selectedStem == nil ? "未选" : i.stemLabel, "state": i.state.display,
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
        public var numberPattern: String
        public var keySuggestion: KeySuggestion?
        public var voicings: [SkeletonVoicing]
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
        var key: KeySuggestion?
        if let k = obj["keySuggestion"] as? [String: Any], let t = k["tonic"] as? String, Pitch.parsePitchClass(t) != nil {
            key = KeySuggestion(tonic: t, mode: k["mode"] as? String == "minor" ? "minor" : "major", modeName: k["modeName"] as? String ?? "",
                                agreesWithCurrent: k["agreesWithCurrent"] as? Bool ?? true, reason: k["reason"] as? String ?? "")
        }
        let voicings = (obj["voicings"] as? [[String: Any]] ?? []).compactMap { v -> SkeletonVoicing? in
            guard let e = v["eventId"] as? String, order[e] != nil else { return nil }
            return SkeletonVoicing(eventId: e, description: v["description"] as? String ?? "")
        }
        return Parsed(backbone: backbone, relations: relations, alternatives: alternatives, summary: obj["summary"] as? String ?? "",
                      numberPattern: obj["numberPattern"] as? String ?? "", keySuggestion: key, voicings: voicings,
                      explanation: obj["explanation"] as? String ?? "", suggestedTags: obj["suggestedTags"] as? [String] ?? [])
    }

    static func extractJSON(_ text: String) -> [String: Any]? {
        if let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8))) as? [String: Any]
    }
}
