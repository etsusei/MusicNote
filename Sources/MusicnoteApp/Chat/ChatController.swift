import Foundation
import MusicnoteCore
import Observation

struct MentionOption: Identifiable, Hashable {
    var id: String { "\(kind.rawValue):\(objectId)" }
    var kind: MentionKind
    var objectId: UUID
    var title: String
    var subtitle: String
}

@MainActor @Observable
final class ChatController {
    unowned let app: AppModel
    var conversations: [Conversation] = []
    var currentId: UUID?
    var messages: [Message] = []
    var highlights: [Highlight] = []
    var draft = ""
    var pendingMentions: [MentionOption] = []
    var sending = false
    var streamingText = ""
    var statusNote: String?
    var scrollTarget: UUID?
    var flashHighlight: UUID?
    var lastError: ProviderError?
    private var sendTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        conversations = app.store.all(Conversation.self).sorted { $0.updatedAt > $1.updatedAt }
        if let first = conversations.first { select(first.id) }
    }

    var current: Conversation? { conversations.first { $0.id == currentId } }
    var store: Store { app.store }

    func newConversation() {
        var c = Conversation(provider: app.settings.defaultProvider)
        c.model = app.settings.providerModels[c.provider]
        c.effort = app.settings.providerEfforts[c.provider]
        try? store.save(c)
        conversations.insert(c, at: 0)
        select(c.id)
    }

    func select(_ id: UUID) {
        currentId = id
        messages = store.all(Message.self, owner: id)
        highlights = store.all(Highlight.self, owner: id)
        streamingText = ""
        statusNote = nil
    }

    func delete(_ c: Conversation) {
        try? store.transaction { tx in
            for m in store.all(Message.self, owner: c.id) { try tx.delete(Message.self, id: m.id) }
            for h in store.all(Highlight.self, owner: c.id) { try tx.delete(Highlight.self, id: h.id) }
            try tx.delete(Conversation.self, id: c.id)
        }
        conversations.removeAll { $0.id == c.id }
        if currentId == c.id { if let f = conversations.first { select(f.id) } else { currentId = nil; messages = [] } }
    }

    func update(_ c: Conversation) {
        try? store.save(c)
        if let i = conversations.firstIndex(where: { $0.id == c.id }) { conversations[i] = c }
    }

    // MARK: Mentions

    func mentionOptions(_ query: String) -> [MentionOption] {
        let q = query.lowercased()
        var out: [MentionOption] = []
        for s in app.songs {
            out.append(MentionOption(kind: .song, objectId: s.id, title: s.title, subtitle: "歌曲 · \(s.artist)"))
            for i in app.items(of: s.id) {
                out.append(MentionOption(kind: .analysis, objectId: i.id, title: "\(s.title) · \(i.title)",
                                         subtitle: "分析 · \(formatTime(us: i.trimStartUs, millis: false))–\(formatTime(us: i.trimEndUs, millis: false)) · \(i.state.display)"))
            }
        }
        for c in conversations where c.id != currentId {
            out.append(MentionOption(kind: .conversation, objectId: c.id, title: c.title, subtitle: "整段会话"))
        }
        guard !q.isEmpty else { return Array(out.prefix(30)) }
        return out.filter { $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    func addMention(_ o: MentionOption) {
        if !pendingMentions.contains(o) { pendingMentions.append(o) }
    }

    /// Resolves mentions into text blocks plus the versions they were resolved at.
    private func resolve(_ options: [MentionOption], provider: ChatProvider) async -> (String, [Mention]) {
        let builder = SnapshotBuilder(store: store)
        var blocks: [String] = []
        var mentions: [Mention] = []
        for o in options {
            switch o.kind {
            case .song:
                guard let s = app.song(o.objectId) else { continue }
                let snap = builder.songSnapshot(s)
                blocks.append("【@歌曲 \(s.title)】包含 \(app.items(of: s.id).count) 个分析子项：\n" + SnapshotBuilder.json(snap))
                mentions.append(Mention(kind: .song, objectId: s.id, title: o.title, revisions: [:], scope: "song", complete: true))
            case .analysis:
                guard let i = app.item(o.objectId) else { continue }
                let snap = builder.analysisSnapshot(i)
                let h = builder.latestHarmony(i.id)
                var note = ""
                if !app.harmonyStale(i).isEmpty { note = "（注意：" + app.harmonyStale(i).joined(separator: "；") + "）" }
                blocks.append("【@分析 \(o.title)】\(note)\n" + SnapshotBuilder.json(snap))
                mentions.append(Mention(kind: .analysis, objectId: i.id, title: o.title,
                                        revisions: ["midi": i.confirmedMidiRevision ?? 0, "harmony": h?.revision ?? 0, "timing": i.timingRevision],
                                        scope: "analysis", complete: true))
            case .conversation:
                var visited: Set<UUID> = [currentId ?? UUID()]
                let (text, complete, rev) = await conversationText(o.objectId, visited: &visited, provider: provider)
                blocks.append("【@整段会话 \(o.title)】\(complete ? "" : "（引用未完整载入）")\n" + text)
                mentions.append(Mention(kind: .conversation, objectId: o.objectId, title: o.title, revisions: ["conversation": rev],
                                        scope: "wholeConversation", complete: complete))
            }
        }
        return (blocks.joined(separator: "\n\n"), mentions)
    }

    /// Whole-conversation snapshot. Nested conversation mentions already visited are
    /// named but not expanded (A cites B cites A). Oversized transcripts are condensed in
    /// batches by the provider, keeping message ranges, rather than cut to the last few.
    private func conversationText(_ id: UUID, visited: inout Set<UUID>, provider: ChatProvider) async -> (String, Bool, Int) {
        guard !visited.contains(id), let conv = store.fetch(Conversation.self, id: id) else { return ("（已在上层引用，不重复展开）", true, 0) }
        visited.insert(id)
        let msgs = store.all(Message.self, owner: id)
        var lines: [String] = []
        for m in msgs {
            var t = "#\(m.sequence) \(m.role == .user ? "用户" : "助手")：\(m.content)"
            let nested = m.mentions.filter { $0.kind == .conversation }
            if !nested.isEmpty { t += "\n（该消息引用了会话：" + nested.map(\.title).joined(separator: "、") + "）" }
            lines.append(t)
        }
        let full = lines.joined(separator: "\n")
        let budget = ContextBudget(actualWindow: current?.contextWindow ?? 200_000)
        if ContextBudget.estimateTokens(full) < budget.capacity / 4 { return (full, true, conv.revision + msgs.count) }
        statusNote = "整段会话已纳入上下文整理"
        // Condense in ~40k-token batches.
        var batches: [[String]] = [[]]
        var size = 0
        for l in lines {
            let t = ContextBudget.estimateTokens(l)
            if size + t > 40_000, !batches[batches.count - 1].isEmpty { batches.append([]); size = 0 }
            batches[batches.count - 1].append(l); size += t
        }
        var parts: [String] = []
        var complete = true
        for (i, b) in batches.enumerated() {
            let prompt = "请把下面这段会话记录（第 \(i + 1)/\(batches.count) 批）整理成要点，保留所有和弦、结论、未解决问题，并标注对应的消息编号范围。只输出整理结果。\n\n" + b.joined(separator: "\n")
            if let r = try? await provider.send(ProviderTurn(sessionId: nil, systemPrompt: "你负责整理对话记录，忠实、不增删事实。", text: prompt, model: nil, effort: "low")) { _ in } {
                parts.append("（消息批次 \(i + 1)：\(b.first?.prefix(8) ?? "")…）\n" + r.text)
            } else { complete = false }
        }
        return (parts.joined(separator: "\n\n"), complete, conv.revision + msgs.count)
    }

    // MARK: Send

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        if currentId == nil { newConversation() }
        guard var conv = current else { return }
        let mentionOptions = pendingMentions
        draft = ""
        pendingMentions = []
        let requestId = UUID()
        var user = Message(conversationId: conv.id, sequence: (messages.last?.sequence ?? 0) + 1, role: .user, content: text)
        user.requestId = requestId
        messages.append(user)
        try? store.save(user)
        if conv.title == "新会话" { conv.title = String(text.prefix(24)) }
        conv.updatedAt = Date()
        update(conv)
        run(user: user, mentionOptions: mentionOptions)
    }

    func retry(_ assistant: Message) {
        guard let idx = messages.firstIndex(where: { $0.id == assistant.id }), idx > 0 else { return }
        let user = messages[idx - 1]
        try? store.delete(Message.self, id: assistant.id)
        messages.remove(at: idx)
        let options = user.mentions.map { MentionOption(kind: $0.kind, objectId: $0.objectId, title: $0.title, subtitle: "") }
        run(user: user, mentionOptions: options)
    }

    func cancel() { sendTask?.cancel() }

    private func run(user: Message, mentionOptions: [MentionOption]) {
        guard var conv = current else { return }
        let pid = conv.provider
        guard let provider = app.providers[pid] else { return }
        let model = conv.model ?? app.settings.providerModels[pid]
        let effort = app.validEffort(pid, model: model, effort: conv.effort ?? app.settings.providerEfforts[pid])
        sending = true
        streamingText = ""
        lastError = nil
        var assistant = Message(conversationId: conv.id, sequence: user.sequence + 1, role: .assistant, content: "", status: .streaming)
        assistant.requestId = user.requestId
        assistant.provider = pid
        assistant.model = model
        sendTask = Task { [weak self] in
            guard let self else { return }
            let (mentionText, mentions) = await self.resolve(mentionOptions, provider: provider)
            var userWithMentions = user
            userWithMentions.mentions = mentions
            try? self.store.save(userWithMentions)
            if let i = self.messages.firstIndex(where: { $0.id == user.id }) { self.messages[i] = userWithMentions }
            self.messages.append(assistant)

            // Context budget: compact when the next send would cross the trigger.
            let window = conv.contextWindow ?? 200_000
            let budget = ContextBudget(actualWindow: window)
            let projected = (conv.lastTokens ?? 0) + ContextBudget.estimateTokens(user.content + mentionText) + 2000
            if budget.shouldCompact(projectedTokens: projected) {
                await self.compact(&conv, provider: provider)
            }

            var binding = conv.bindings.first { $0.provider == pid }
            var turnText = user.content
            if !mentionText.isEmpty { turnText += "\n\n—— 引用数据（发送时快照）——\n" + mentionText }
            if binding == nil || binding!.syncedThroughSequence < user.sequence - 1 {
                // New backend session (first message, provider switch, or after compaction): replay local history.
                let history = self.historyText(conv, before: user.sequence)
                if !history.isEmpty { turnText = "以下是本会话此前的记录（来自本地完整记录）：\n" + history + "\n\n—— 新消息 ——\n" + turnText }
                binding = ProviderBinding(provider: pid, backendSessionId: nil, syncedThroughSequence: 0)
            }
            let system = TeacherPrompt.system + self.referencesBlock()
            do {
                let result = try await provider.send(ProviderTurn(sessionId: binding?.backendSessionId, systemPrompt: system,
                                                                  text: turnText, model: model, effort: effort)) { [weak self] d in
                    Task { @MainActor in self?.streamingText += d }
                }
                assistant.content = result.text.isEmpty ? self.streamingText : result.text
                assistant.status = .complete
                assistant.usageTokens = result.contextTokens
                binding = ProviderBinding(provider: pid, backendSessionId: result.sessionId, syncedThroughSequence: assistant.sequence)
                conv.bindings.removeAll { $0.provider == pid }
                conv.bindings.append(binding!)
                conv.lastTokens = result.contextTokens
                if let w = result.contextWindow { conv.contextWindow = w }
            } catch is CancellationError {
                assistant.content = self.streamingText
                assistant.status = .incomplete
                assistant.error = "已停止"
            } catch let e as ProviderError {
                if case .incomplete(_, let partial) = e { assistant.content = partial; assistant.status = .incomplete } else {
                    assistant.content = self.streamingText
                    assistant.status = self.streamingText.isEmpty ? .failed : .incomplete
                }
                assistant.error = e.localizedDescription
                self.lastError = e
                if case .loginRequired = e { self.app.providerStatus[pid] = ProviderStatus(state: .expired) }
                if case .quotaExhausted = e { self.app.providerStatus[pid] = ProviderStatus(state: .quotaExhausted) }
            } catch {
                assistant.content = self.streamingText
                assistant.status = self.streamingText.isEmpty ? .failed : .incomplete
                assistant.error = error.localizedDescription
            }
            try? self.store.save(assistant)
            if let i = self.messages.firstIndex(where: { $0.id == assistant.id }) { self.messages[i] = assistant }
            conv.updatedAt = Date()
            conv.revision += 1
            self.update(conv)
            self.streamingText = ""
            self.sending = false
        }
    }

    private func historyText(_ conv: Conversation, before seq: Int) -> String {
        let summary = conv.summaries.last
        var parts: [String] = []
        if let s = summary { parts.append("【已整理的早期上下文（至 #\(s.throughSequence)）】\n" + s.summary) }
        for m in store.all(Message.self, owner: conv.id) where m.sequence < seq && m.sequence > (summary?.throughSequence ?? 0) {
            guard m.status == .complete || m.status == .incomplete else { continue }
            parts.append("#\(m.sequence) \(m.role == .user ? "用户" : "助手")：\(m.content)")
        }
        return parts.joined(separator: "\n")
    }

    /// Summarizes older messages into a ContextSummary; local messages are never deleted.
    private func compact(_ conv: inout Conversation, provider: ChatProvider) async {
        let msgs = store.all(Message.self, owner: conv.id)
        let keepRecent = 6
        guard msgs.count > keepRecent else { return }
        let cutoff = msgs[msgs.count - keepRecent - 1].sequence
        let from = conv.summaries.last?.throughSequence ?? 0
        let old = msgs.filter { $0.sequence > from && $0.sequence <= cutoff }
        guard !old.isEmpty else { return }
        var text = conv.summaries.last.map { "已有摘要：\n\($0.summary)\n\n" } ?? ""
        text += old.map { "#\($0.sequence) \($0.role == .user ? "用户" : "助手")：\($0.content)" }.joined(separator: "\n")
        let prompt = "请把这段音乐学习对话整理成后续继续讨论所需的上下文：保留讨论过的歌曲/片段、和弦与级数、结论、未解决问题，以及引用过的数据版本。\n\n" + text
        if let r = try? await provider.send(ProviderTurn(sessionId: nil, systemPrompt: "你负责整理对话上下文，忠实、不增删事实。", text: prompt, model: nil, effort: "low")) { _ in } {
            conv.summaries.append(ContextSummary(throughSequence: cutoff, summary: r.text, createdAt: Date()))
            conv.bindings = [] // next turn starts a fresh backend session seeded with the summary
            conv.lastTokens = nil
            statusNote = "已整理上下文"
            update(conv)
        }
    }

    private func referencesBlock() -> String {
        let refs = store.all(ReferenceMaterial.self).filter(\.isRead)
        guard !refs.isEmpty else { return "" }
        return "\n\n已审核的参考材料（实际读取的内容，回答时注明使用了哪条）：\n" + refs.map {
            "[\($0.title)｜\($0.section)｜\($0.sourceURL)]\n\($0.content.prefix(6000))"
        }.joined(separator: "\n\n")
    }

    // MARK: Highlights

    func addHighlight(message: Message, range: NSRange, bookmarked: Bool) {
        guard let conv = currentId, range.length > 0 else { return }
        let ns = message.content as NSString
        guard NSMaxRange(range) <= ns.length else { return }
        let h = Highlight(conversationId: conv, messageId: message.id, rangeStart: range.location, rangeLength: range.length,
                          quotedText: ns.substring(with: range), bookmarked: bookmarked)
        try? store.save(h)
        highlights.append(h)
    }

    func removeHighlight(_ h: Highlight) {
        try? store.delete(Highlight.self, id: h.id)
        highlights.removeAll { $0.id == h.id }
    }

    func allBookmarks() -> [Highlight] { store.all(Highlight.self).filter(\.bookmarked).sorted { $0.createdAt > $1.createdAt } }

    func jump(to h: Highlight) {
        app.showRight = true
        select(h.conversationId)
        scrollTarget = h.messageId
        flashHighlight = h.id
    }
}
