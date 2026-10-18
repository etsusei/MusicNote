import MusicnoteCore
import SwiftUI

struct ChatPanel: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showMentions = false
    @ViewState private var showInspirations = false
    @ViewState private var showList = false

    private var chat: ChatController { model.chat }

    var body: some View {
        @Bindable var chat = model.chat
        VStack(spacing: 0) {
            header
            Divider()
            if showList { conversationList } else {
                messagesView
                Divider()
                composer
            }
        }
        .background(Theme.surface)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { showList.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet")
                        Text(chat.current?.title ?? "全局聊天").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(Theme.textPrimary).contentShape(Rectangle())
                }.buttonStyle(.plain).help("会话列表")
                Spacer()
                Button { chat.newConversation(); showList = false } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("新会话")
            }
            statusRow
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    /// Provider used by the current conversation, or the default for the next one.
    private var activeProvider: String { chat.current?.provider ?? model.settings.defaultProvider }

    private var statusRow: some View {
        let pid = activeProvider
        let status = model.providerStatus[pid]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusPill(text: "\(model.providers[pid]?.displayName ?? pid) · \(status?.state.display ?? "…")",
                           color: status?.state == .connected ? Theme.success : Theme.warning)
                if let note = status?.quotaNote { Text(note).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                Spacer()
                if status?.state != .connected {
                    Button("连接") { login(pid) }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
            if let conv = chat.current { usageLine(conv) }
        }
    }

    /// Model choice bound to the current conversation, or to the defaults when there is none.
    private var modelChoice: some View {
        if let conv = chat.current {
            return AnyView(ModelEffortPicker(
                provider: Binding(get: { conv.provider }, set: { p in var c = conv; c.provider = p; c.model = nil; c.effort = nil; chat.update(c) }),
                modelId: Binding(get: { conv.model ?? model.settings.providerModels[conv.provider] },
                                 set: { m in var c = conv; c.model = m; chat.update(c) }),
                effort: Binding(get: { model.validEffort(conv.provider, model: conv.model ?? model.settings.providerModels[conv.provider],
                                                         effort: conv.effort ?? model.settings.providerEfforts[conv.provider]) },
                                set: { e in var c = conv; c.effort = e; chat.update(c) }),
                onNote: { chat.statusNote = $0 }))
        }
        let pid = model.settings.defaultProvider
        return AnyView(ModelEffortPicker(
            provider: Binding(get: { model.settings.defaultProvider }, set: { model.settings.defaultProvider = $0; model.saveSettings() }),
            modelId: Binding(get: { model.settings.providerModels[pid] }, set: { model.settings.providerModels[pid] = $0; model.saveSettings() }),
            effort: Binding(get: { model.settings.providerEfforts[pid] }, set: { model.settings.providerEfforts[pid] = $0; model.saveSettings() }),
            onNote: { chat.statusNote = $0 }))
    }

    private func usageLine(_ conv: Conversation) -> some View {
        HStack(spacing: 6) {
            if let t = conv.lastTokens {
                let budget = ContextBudget(actualWindow: conv.contextWindow ?? 200_000)
                Text("上下文 \(t / 1000)k / \(budget.capacity / 1000)k · 整理阈值 \(budget.trigger / 1000)k")
                    .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
            if let s = chat.statusNote { Text(s).font(.system(size: 10)).foregroundStyle(Theme.accent) }
        }
    }

    private func login(_ pid: String) {
        Task {
            do {
                try await model.providers[pid]?.login()
            } catch { model.report(error) }
            await model.refreshProviders()
        }
    }

    // MARK: List

    private var conversationList: some View {
        List {
            ForEach(chat.conversations) { c in
                HStack {
                    VStack(alignment: .leading) {
                        Text(c.title).font(.control13).lineLimit(1)
                        Text("\(model.providers[c.provider]?.displayName ?? c.provider) · \(c.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { chat.select(c.id); showList = false }
                .contextMenu { Button("删除会话", role: .destructive) { chat.delete(c) } }
            }
        }
        .listStyle(.plain)
    }

    // MARK: Messages

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty {
                        Text("全局会话不绑定歌曲。输入 @ 引用歌曲、具体片段分析或另一整段会话，可以同时比较多个对象。")
                            .font(.caption12).foregroundStyle(Theme.textSecondary).padding(.top, 20)
                    }
                    ForEach(chat.messages) { m in
                        MessageView(message: m, streaming: chat.sending && m.status == .streaming ? chat.streamingText : nil)
                            .id(m.id)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 16)
            }
            .onChange(of: chat.messages.count) { _, _ in if let last = chat.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            .onChange(of: chat.scrollTarget) { _, t in if let t { withAnimation { proxy.scrollTo(t, anchor: .center) }; chat.scrollTarget = nil } }
            .onChange(of: chat.streamingText) { _, _ in if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
    }

    // MARK: Composer

    private var composer: some View {
        @Bindable var chat = model.chat
        return VStack(alignment: .leading, spacing: 6) {
            if !chat.pendingMentions.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(chat.pendingMentions) { o in
                        HStack(spacing: 3) {
                            Text((o.kind == .inspiration ? "#" : "@") + o.title).font(.caption12).lineLimit(1)
                            Button { chat.pendingMentions.removeAll { $0 == o } } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Theme.selectionFill))
                        .help(o.subtitle + (o.kind == .conversation ? "（引用整个会话）" : ""))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $chat.draft)
                        .font(.body14).frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .onChange(of: chat.draft) { _, t in
                            showMentions = mentionQuery(t) != nil
                            showInspirations = !showMentions && inspirationQuery(t) != nil
                        }
                    if chat.draft.isEmpty {
                        Text("问问老师…  @ 引用 · # 灵感进行 · ⌘↩ 发送").font(.body14).foregroundStyle(Theme.textSecondary.opacity(0.8))
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                HStack(spacing: 2) {
                    Button { showMentions = true; if !chat.draft.hasSuffix("@") { chat.draft += "@" } } label: {
                        Image(systemName: "at").frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help("引用")
                    Button {
                        if !(chat.draft.isEmpty || chat.draft.hasSuffix(" ") || chat.draft.hasSuffix("\n")) { chat.draft += " " }
                        chat.draft += "#"; showInspirations = true
                    } label: { Image(systemName: "number").frame(width: 24, height: 24).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help("引用灵感集合里的进行")
                    Spacer(minLength: 4)
                    if chat.sending {
                        Button { chat.cancel() } label: {
                            Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                                .frame(width: 28, height: 28).background(Circle().fill(Theme.textPrimary)).foregroundStyle(Theme.surface)
                        }.buttonStyle(.plain).help("停止")
                    } else {
                        let empty = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button { chat.send() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                                .frame(width: 28, height: 28).background(Circle().fill(empty ? Theme.controlBorder : Theme.accent))
                                .foregroundStyle(Theme.onAccent)
                        }
                        .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(empty).help("发送（⌘↩）")
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.background))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.borderSubtle))
            .popover(isPresented: $showMentions, arrowEdge: .top) { mentionPicker }
            .popover(isPresented: $showInspirations, arrowEdge: .top) { inspirationPicker }
            modelChoice.foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
        }
        .padding(10)
    }

    /// "#" at the start or after a space opens 灵感集合 (a "#" inside a chord name like C#m doesn't).
    private func inspirationQuery(_ t: String) -> String? {
        guard let h = t.lastIndex(of: "#") else { return nil }
        if h > t.startIndex, !t[t.index(before: h)].isWhitespace { return nil }
        let q = t[t.index(after: h)...]
        return q.contains("\n") || q.count > 24 ? nil : String(q)
    }

    private var inspirationPicker: some View {
        let q = inspirationQuery(chat.draft) ?? ""
        let options = chat.inspirationOptions(q)
        return VStack(alignment: .leading, spacing: 0) {
            Text("引用灵感集合里的进行").font(.caption12).foregroundStyle(Theme.textSecondary).padding(8)
            if options.isEmpty {
                Text(model.inspirationList.isEmpty ? "灵感集合还是空的" : "没有匹配的进行").font(.caption12).foregroundStyle(Theme.textSecondary).padding(8)
            }
            List(options) { o in
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.title).font(.control13)
                    Text(o.subtitle).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    chat.addMention(o)
                    if let h = chat.draft.lastIndex(of: "#") { chat.draft = String(chat.draft[..<h]) }
                    showInspirations = false
                }
            }
            .frame(width: 320, height: 260)
        }
    }

    private func mentionQuery(_ t: String) -> String? {
        guard let at = t.lastIndex(of: "@") else { return nil }
        let q = t[t.index(after: at)...]
        return q.contains(" ") || q.contains("\n") || q.count > 24 ? nil : String(q)
    }

    private var mentionPicker: some View {
        let q = mentionQuery(chat.draft) ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            Text("引用歌曲、片段分析或整段会话").font(.caption12).foregroundStyle(Theme.textSecondary).padding(8)
            List(chat.mentionOptions(q)) { o in
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.title).font(.control13)
                    Text(o.subtitle).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    chat.addMention(o)
                    if let at = chat.draft.lastIndex(of: "@") { chat.draft = String(chat.draft[..<at]) }
                    showMentions = false
                }
            }
            .frame(width: 320, height: 300)
        }
    }
}

struct MessageView: View {
    @Environment(AppModel.self) private var model
    var message: Message
    var streaming: String?
    @ViewState private var expandMentions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(message.role == .user ? "你" : "老师").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(message.role == .user ? Theme.textSecondary : Theme.accent)
                if message.role == .assistant, let p = message.provider {
                    Text(model.providers[p]?.displayName ?? p).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                switch message.status {
                case .incomplete: StatusPill(text: "未完成", color: Theme.warning)
                case .failed: StatusPill(text: "失败", color: Theme.error)
                default: EmptyView()
                }
            }
            if !message.mentions.isEmpty {
                Button { expandMentions.toggle() } label: {
                    Text(message.mentions.map { ($0.kind == .inspiration ? "#" : "@") + $0.title }.joined(separator: " ")).font(.caption12).foregroundStyle(Theme.accent).lineLimit(expandMentions ? nil : 1)
                }.buttonStyle(.plain)
                if expandMentions {
                    ForEach(message.mentions, id: \.objectId) { m in
                        Text("\(m.title)：\(m.scope == "wholeConversation" ? "整段会话" : m.scope) · 版本 \(m.revisions.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))\(m.complete ? "" : " · 引用未完整载入")")
                            .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            let text = streaming ?? message.content
            if text.isEmpty && streaming != nil {
                ProgressView().controlSize(.small)
            } else if message.role == .assistant {
                RichTextView(text: text, highlights: highlightRanges, onHighlight: { r, bm in model.chat.addHighlight(message: message, range: r, bookmarked: bm) })
            } else {
                Text(text).font(.body14).textSelection(.enabled)
            }
            if let e = message.error {
                HStack {
                    Text(e).font(.caption12).foregroundStyle(Theme.warning)
                    if message.role == .assistant, message.status != .complete, !model.chat.sending {
                        Button("重试") { model.chat.retry(message) }.buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                }
            }
        }
        .padding(message.role == .user ? 12 : 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(message.role == .user ? Theme.background : Color.clear))
    }

    private var highlightRanges: [(NSRange, Bool)] {
        model.chat.highlights.filter { $0.messageId == message.id }.map {
            (NSRange(location: $0.rangeStart, length: $0.rangeLength), model.chat.flashHighlight == $0.id)
        }
    }
}
