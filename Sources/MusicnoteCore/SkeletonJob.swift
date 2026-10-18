import Foundation

/// One skeleton generation, shared by the app and the command line: the request text, and
/// filling a Skeleton from the model's answer.
public enum SkeletonJob {
    public static func prompt(item: AnalysisItem, store: Store) -> String {
        let snapshot = SnapshotBuilder(store: store).analysisSnapshot(item)
        var text = TeacherPrompt.skeletonTask + "\n\n数据：\n" + SnapshotBuilder.json(snapshot)
        let refs = store.all(ReferenceMaterial.self).filter(\.isRead)
        if !refs.isEmpty {
            text += "\n\n参考材料（已实际读取）：\n" + refs.map { "[\($0.title) · \($0.section)] \($0.content.prefix(4000))" }.joined(separator: "\n\n")
        }
        return text
    }

    /// Fills `sk` from a structured answer; false when it doesn't parse.
    public static func fill(_ sk: inout Skeleton, answer: String, harmony: HarmonyRevision, item: AnalysisItem) -> Bool {
        guard let parsed = SkeletonParser.parse(answer, events: harmony.events) else { return false }
        sk.backboneEventIds = parsed.backbone
        sk.relations = parsed.relations
        sk.alternatives = parsed.alternatives
        sk.explanation = parsed.explanation
        sk.summary = parsed.summary.isEmpty ? nil : parsed.summary
        // Numbered degrees are computed, not taken from the model: 1 = major tonic,
        // minor keys counted from the relative major.
        let byId = Dictionary(uniqueKeysWithValues: harmony.events.map { ($0.id, $0) })
        let numKey = parsed.keySuggestion?.key ?? item.timing?.key ?? harmony.key
        let pattern = Degrees.numberPattern(parsed.backbone.compactMap { byId[$0]?.symbol }, key: numKey)
        sk.numberPattern = onePass(pattern) ?? (parsed.numberPattern.isEmpty ? nil : parsed.numberPattern)
        sk.keySuggestion = parsed.keySuggestion
        sk.voicings = parsed.voicings
        sk.keyUsed = item.timing?.key.display
        sk.status = .succeeded
        sk.error = parsed.suggestedTags.isEmpty ? nil : "建议标签：" + parsed.suggestedTags.joined(separator: "、")
        return true
    }

    /// "6-♭7-6-6-♭7-6" → "6-♭7-6" when the backbone simply repeats.
    public static func onePass(_ pattern: String) -> String? {
        let parts = pattern.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }
        for n in 1...parts.count where parts.count % n == 0 {
            let unit = Array(parts[0..<n])
            if stride(from: 0, to: parts.count, by: n).allSatisfy({ Array(parts[$0..<($0 + n)]) == unit }) { return unit.joined(separator: "-") }
        }
        return pattern
    }

    /// Two attempts at a structured answer; a second unparsable one is kept as plain text.
    public static func run(item: AnalysisItem, harmony: HarmonyRevision, store: Store, provider: ChatProvider,
                           model: String?, effort: String?, into sk: inout Skeleton) async {
        let text = prompt(item: item, store: store)
        var lastText = ""
        for _ in 0..<2 {
            do {
                let r = try await provider.send(ProviderTurn(sessionId: nil, systemPrompt: TeacherPrompt.system, text: text,
                                                             model: model, effort: effort, outputSchema: TeacherPrompt.skeletonSchema)) { _ in }
                lastText = r.text
                if fill(&sk, answer: r.text, harmony: harmony, item: item) { return }
            } catch {
                sk.status = .failed
                sk.error = error.localizedDescription
                return
            }
        }
        sk.status = .succeeded
        sk.unstructured = true
        sk.explanation = lastText
    }
}
