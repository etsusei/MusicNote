import AppKit
import MusicnoteCore
import SwiftUI

enum EffortLabel {
    static func text(_ e: String) -> String {
        switch e {
        case "minimal": "极低"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "很高"
        case "max": "最高"
        case "ultra": "极限"
        default: e
        }
    }
}

extension AppModel {
    /// The model a choice resolves to: the chosen id, else the provider's default.
    func resolvedModel(_ provider: String, _ id: String?) -> ProviderModel? {
        let list = providerModels[provider] ?? []
        if let id, let m = list.first(where: { $0.id == id }) { return m }
        if let id, !id.isEmpty, id != "default" {
            // A custom name the client accepts but cannot list: assume the client's effort levels.
            let efforts = list.first?.efforts ?? []
            return ProviderModel(id: id, name: id, efforts: efforts, defaultEffort: nil, isDefault: false, verified: false)
        }
        return list.first { $0.isDefault } ?? list.first
    }

    /// Keeps an effort only if the model supports it; otherwise nil (the model's default).
    func validEffort(_ provider: String, model: String?, effort: String?) -> String? {
        guard let effort, let m = resolvedModel(provider, model) else { return nil }
        return m.efforts.contains(effort) ? effort : nil
    }
}

/// Provider / model / reasoning-effort menus. Lists come from each client's real
/// capabilities; Claude Code can't list models, so its documented aliases are offered
/// plus a custom name, marked 能力未确认.
struct ModelEffortPicker: View {
    @Environment(AppModel.self) private var model
    var provider: Binding<String>?
    var fixedProvider: String = ""
    @Binding var modelId: String?
    @Binding var effort: String?
    var onNote: (String) -> Void = { _ in }

    private var pid: String { provider?.wrappedValue ?? fixedProvider }

    var body: some View {
        let models = model.providerModels[pid] ?? []
        let current = model.resolvedModel(pid, modelId)
        HStack(spacing: 6) {
            if let provider {
                Menu {
                    ForEach(model.providers.keys.sorted(), id: \.self) { id in
                        Button {
                            provider.wrappedValue = id; modelId = nil; effort = nil
                        } label: {
                            Label("\(model.providers[id]!.displayName)（\(model.providerStatus[id]?.state.display ?? "…")）",
                                  systemImage: id == pid ? "checkmark" : "")
                        }
                    }
                } label: { Text(model.providers[pid]?.displayName ?? pid) }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            Menu {
                if models.isEmpty {
                    Text(model.providerStatus[pid]?.state == .connected ? "模型列表加载中…" : "未连接，无法读取模型列表")
                }
                ForEach(models) { m in
                    Button { choose(m.id, models: models) } label: {
                        Label(m.name + (m.isDefault ? "（默认）" : "") + (m.verified ? "" : "（能力未确认）"),
                              systemImage: m.id == current?.id ? "checkmark" : "")
                    }
                }
                if models.contains(where: { !$0.verified }) {
                    Divider()
                    Button("自定义模型名…") { askCustom() }
                }
                Divider()
                Button("刷新模型列表") { Task { await model.refreshProviders() } }
            } label: { Text(current?.name ?? "选择模型").lineLimit(1).truncationMode(.tail) }
                .menuStyle(.borderlessButton).frame(maxWidth: 150, alignment: .leading)
            if let efforts = current?.efforts, !efforts.isEmpty {
                Menu {
                    Button { effort = nil } label: {
                        Label("默认" + (current?.defaultEffort.map { "（\(EffortLabel.text($0))）" } ?? ""), systemImage: effort == nil ? "checkmark" : "")
                    }
                    ForEach(efforts, id: \.self) { e in
                        Button { effort = e } label: { Label("\(EffortLabel.text(e))  \(e)", systemImage: effort == e ? "checkmark" : "") }
                    }
                } label: {
                    Text("推理 " + EffortLabel.text(effort ?? current?.defaultEffort ?? "默认"))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("推理强度：只列出这个模型支持的档位")
            }
        }
        .font(.caption12)
    }

    private func choose(_ id: String, models: [ProviderModel]) {
        modelId = id
        if let e = effort, !(models.first { $0.id == id }?.efforts.contains(e) ?? true) {
            effort = nil
            onNote("新模型不支持“\(EffortLabel.text(e))”推理强度，已改用它的默认档")
        }
    }

    private func askCustom() {
        let alert = NSAlert()
        alert.messageText = "自定义模型名"
        alert.informativeText = "填写客户端接受的模型别名或完整名称（例如 opus、sonnet，或完整模型 ID）。"
        let field = NSTextField(string: modelId ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let v = field.stringValue.trimmingCharacters(in: .whitespaces)
            modelId = v.isEmpty ? nil : v
        }
    }
}
