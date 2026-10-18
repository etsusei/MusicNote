import MusicnoteCore
import SwiftUI

enum AutoToolLabel {
    static func text(_ tool: String) -> String {
        switch tool {
        case "inspect_analysis": "查看现状"
        case "run_logic_chords": "Logic 和弦候选"
        case "run_transcription": "转录"
        case "align_transcriptions": "对齐双转录"
        case "bar_evidence": "读小节证据"
        case "local_audio_check": "定向复核"
        case "harmony_draft": "看程序草稿"
        case "note_review": "记录复核"
        case "submit_analysis": "提交结果"
        default: tool
        }
    }
}

/// Starting the model's analysis. The result isn't shown here: it opens the harmony below for
/// checking (核对中), where it is edited and confirmed.
struct AutoAnalysisSection: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    @AppStorage("autoProvider") private var providerId = "codex"
    @ViewState private var confirmReplace = false

    private static let providers = [("codex", "Codex"), ("claude", "Claude Code")]
    private var connected: Bool { model.providerStatus[providerId]?.state == .connected }
    private var providerName: String { Self.providers.first { $0.0 == providerId }?.1 ?? providerId }

    var body: some View {
        let _ = model.dataVersion
        let running = model.autoTasks[item.id] != nil
        let run = model.latestAutoRun(item.id)
        let unchecked = model.uncheckedRun(item.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("模型自主分析").font(.system(size: 14, weight: .semibold))
                Text("Logic 候选 + 双转录 + 局部复核，结果交给你核对").font(.caption12).foregroundStyle(Theme.textSecondary)
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                    Button("停止") { model.cancelAutoAnalysis(item.id) }.buttonStyle(SecondaryButtonStyle(compact: true))
                } else {
                    Picker("", selection: $providerId) {
                        ForEach(Self.providers, id: \.0) { p in
                            Text(p.1 + (model.providerStatus[p.0]?.state == .connected ? "" : "（未连接）")).tag(p.0)
                        }
                    }
                    .labelsHidden().frame(width: 150)
                    .help("模型和推理强度沿用设置里给这个客户端选的")
                    Button("开始分析") { if model.harmonyDraft(item.id) != nil { confirmReplace = true } else { start() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!connected)
                        .help(connected ? "使用 \(providerName)（\(model.settings.providerModels[providerId] ?? "默认模型")）" : "需要先连接 \(providerName)")
                }
            }
            if let run, running || run.status != .succeeded {
                RunProgress(run: run, running: running)
            }
            if let unchecked, !running {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full").foregroundStyle(Theme.accent)
                    Text("上次分析的结果还没核对").font(.caption12)
                    Button("开始核对") { model.reviewRun(item.id, run: unchecked) }.buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .confirmationDialog("正在核对的修改会被新结果替换", isPresented: $confirmReplace) {
            Button("开始分析，替换当前草稿") { start() }
            Button("取消", role: .cancel) {}
        } message: { Text("现在有一份还没确定的修改。新的分析结果出来后会替换它。") }
    }

    private func start() { model.startAutoAnalysis(item.id, provider: providerId) }
}

struct RunProgress: View {
    var run: AutoRun
    var running: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if running { ProgressView().controlSize(.small) }
                Text(running ? "分析中" : statusText).font(.system(size: 13, weight: .semibold))
                Text("工具 \(run.toolCalls)/\(run.maxToolCalls) 次 · \(Int((run.finishedAt ?? Date()).timeIntervalSince(run.startedAt))) 秒 · \(run.provider == "claude" ? "Claude Code" : "Codex") \(run.model)")
                    .font(.caption12).foregroundStyle(Theme.textSecondary)
            }
            if let e = run.error, !running { Text(e).font(.caption12).foregroundStyle(Theme.warning) }
            ForEach(Array(run.steps.suffix(running ? 8 : 4).enumerated()), id: \.offset) { _, s in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: s.ok ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(s.ok ? Theme.success : Theme.warning)
                    Text(AutoToolLabel.text(s.tool)).font(.system(size: 12, weight: .medium)).frame(width: 96, alignment: .leading)
                    Text(firstLine(s)).font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
        }
    }

    private var statusText: String {
        switch run.status {
        case .succeeded: "已完成"
        case .cancelled: "已停止"
        case .failed: "没有完成"
        case .interrupted: "被中断"
        default: run.status.rawValue
        }
    }

    private func firstLine(_ s: AutoStep) -> String {
        if s.tool == "note_review" || s.tool == "local_audio_check" || s.tool == "bar_evidence" {
            return s.arguments.replacingOccurrences(of: "\"", with: "").prefix(160).description
        }
        return s.summary.split(separator: "\n").first.map(String.init) ?? ""
    }
}

struct Legend: View {
    var itemId: UUID? = nil
    @AppStorage("foldPushes") private var foldPushes = true
    var body: some View {
        HStack(spacing: 12) {
            chip("主干", fill: true)
            chip("经过 / 连接", fill: false)
            HStack(spacing: 4) { Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.warning); Text("待确认") }
            Toggle(isOn: $foldPushes) { HStack(spacing: 3) { Image(systemName: "arrow.uturn.backward"); Text("提前进入的按进入的拍显示") } }
                .toggleStyle(.checkbox).help("提前一个八分音符按下、延续过拍子的和弦，画在它进入的拍子上；实际时间不变")
            Text("点和弦听实际按法；点小节号听原曲").foregroundStyle(Theme.textSecondary)
            Spacer()
            if let itemId { BarNudge(itemId: itemId) }
        }
        .font(.system(size: 11))
    }
    private func chip(_ t: String, fill: Bool) -> some View {
        Text(t).padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(fill ? Theme.chipFill : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.chipLine, style: StrokeStyle(lineWidth: 1, dash: fill ? [] : [3, 2])))
            .foregroundStyle(fill ? Theme.chipText : Theme.textPrimary)
    }
}

/// Bars in rows of four; each chord is placed at its beat and sized by its length.
/// Manual room to move the bar lines afterwards, by an eighth or a beat; note times stay.
struct BarNudge: View {
    @Environment(AppModel.self) private var model
    var itemId: UUID
    var body: some View {
        HStack(spacing: 2) {
            Text("小节线").foregroundStyle(Theme.textSecondary)
            Button { model.shiftBarLine(itemId, beats: -1) } label: { Image(systemName: "chevron.left.2") }.help("整体提前一拍")
            Button { model.shiftBarLine(itemId, beats: -0.5) } label: { Image(systemName: "chevron.left") }.help("整体提前一个八分音符")
            Button { model.shiftBarLine(itemId, beats: 0.5) } label: { Image(systemName: "chevron.right") }.help("整体推后一个八分音符")
            Button { model.shiftBarLine(itemId, beats: 1) } label: { Image(systemName: "chevron.right.2") }.help("整体推后一拍")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
    }
}
