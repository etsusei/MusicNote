import MusicnoteCore
import SwiftUI

/// The clip's harmony in one of two states.
/// 核对中 (a draft): check it against the audio and fix it — checking material from the model,
/// editable bars, 确定 / 放弃. 已确定: use it — the progression, the original playing with the
/// chords (the sounding one lit), read-only bars, and 修改 to open it again.
struct HarmonySection: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var harmony: HarmonyRevision?
    var draft: HarmonyDraft?

    var body: some View {
        if let draft { ReviewPanel(item: item, draft: draft) }
        else if let harmony { ConfirmedPanel(item: item, harmony: harmony) }
    }

    static func grid(_ item: AnalysisItem, _ h: HarmonyRevision) -> BeatGrid? {
        guard var g = item.timing?.grid else { return nil }
        if g.barAnchorUs == nil { g.barAnchorUs = h.barAnchorUs }
        return g
    }
}

// MARK: - 核对中

private struct ReviewPanel: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var draft: HarmonyDraft
    @ViewState private var confirmDiscard = false

    var body: some View {
        let h = draft.harmony
        let run = draft.runId.flatMap { model.store.fetch(AutoRun.self, id: $0) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.fromModel ? "核对中 · 模型分析的结果" : "核对中 · 修改已确定的和声").font(.system(size: 14, weight: .semibold))
                    Text("对照原曲听，拖和弦移动、拖边缘改长度、空白处点 ＋ 添加、双击改名。确定前不会改动你的和声、MIDI 和骨架。")
                        .font(.caption12).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("放弃") { confirmDiscard = true }.buttonStyle(SecondaryButtonStyle())
                Button("确定") { model.confirmDraft(item.id) }.buttonStyle(PrimaryButtonStyle())
                    .help("存成新的和声版本（旧版本保留），重新生成骨架")
            }
            if let auto = h.auto, draft.fromModel, let g = HarmonySection.grid(item, h) {
                ModelChecks(item: item, harmony: h, auto: auto, grid: g, run: run)
            } else {
                BarLineHint(item: item)
            }
            if let g = HarmonySection.grid(item, h) {
                Legend(itemId: item.id)
                BarProgressionView(item: item, harmony: h, auto: h.auto, grid: g,
                                   edit: { f in model.editDraft(item.id, f) }, undo: { model.undoDraft(item.id) },
                                   undoCount: model.draftUndoCount(item.id), notes: model.draftNotes(draft))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.5)))
        .confirmationDialog("放弃这次核对的修改？", isPresented: $confirmDiscard) {
            Button("放弃修改", role: .destructive) { model.discardDraft(item.id) }
            Button("继续核对", role: .cancel) {}
        } message: { Text(draft.fromModel ? "模型的结果和你的修改都会丢掉，和声回到原来确定的版本。" : "你的修改会丢掉，和声回到原来确定的版本。") }
    }
}

/// What the model leaves to check: its summary, the key check, bar-line advice and the points it
/// was unsure about (each with audio); the review trail and sources are folded away.
private struct ModelChecks: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var harmony: HarmonyRevision
    var auto: AutoHarmony
    var grid: BeatGrid
    var run: AutoRun?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !auto.summary.isEmpty { Text(auto.summary).font(.system(size: 13, weight: .medium)) }
            if let k = auto.key, let key = k.key, key != item.timing?.key {
                KeyCorrectionCard(title: "调性检查：模型判断是 \(k.modeName.isEmpty ? key.display : k.modeName)，和你设定的 \(item.timing?.key.display ?? "") 不同", reason: k.reason,
                                  apply: { model.applyKey(item.id, key) }, applyTitle: "改为 \(key.display)", dismiss: nil)
            } else if let k = auto.key {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.success)
                    Text("调性：\(k.modeName.isEmpty ? (k.key?.display ?? "") : k.modeName)，与设定一致").font(.system(size: 12, weight: .semibold))
                    Text(k.reason).font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            if let sh = auto.barShiftBeats, sh != 0, harmony.params["barAnchorUs"] == String(grid.barAnchorUs ?? 0) {
                BarShiftCard(text: "模型核对小节线后认为要整体挪动：" + (auto.barReason ?? "") + "（和弦时间不变，只是换个格子读。）",
                             shift: sh, apply: { model.shiftBarLine(item.id, beats: sh) }, dismiss: nil)
            }
            if !auto.toConfirm.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("待确认（\(auto.toConfirm.count)）").font(.system(size: 12, weight: .semibold))
                    ForEach(Array(auto.toConfirm.enumerated()), id: \.offset) { _, c in
                        let p = BarEvidence.position(c.startUs, grid: grid)
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "questionmark.circle").foregroundStyle(Theme.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("第 \(p.bar) 小节第 \(BarEvidence.beatText(p.beat)) 拍").font(.system(size: 12, weight: .semibold))
                                Text(c.question).font(.caption12).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Button("听原曲") { model.audition(item.id, startUs: max(0, c.startUs - Int64(grid.beatUs)), endUs: c.startUs + Int64(grid.beatUs * 2), original: true) }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                            Button("听分轨") { model.audition(item.id, startUs: max(0, c.startUs - Int64(grid.beatUs)), endUs: c.startUs + Int64(grid.beatUs * 2), original: false) }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                        }
                    }
                }
            }
            DisclosureGroup("依据（证据来源\(run.map { "、复核 \($0.reviews.count) 次" } ?? "")）") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("证据来源：" + auto.sources.joined(separator: "、") + (run.map { " · \($0.provider == "claude" ? "Claude Code" : "Codex") \($0.model)" } ?? ""))
                        .font(.caption12).foregroundStyle(Theme.textSecondary)
                    ForEach(Array((run?.reviews ?? []).enumerated()), id: \.offset) { _, r in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("问：" + r.question).font(.caption12)
                            if !r.observedEvidence.isEmpty { Text("证据：" + r.observedEvidence).font(.caption12).foregroundStyle(Theme.textSecondary) }
                            if !r.decision.isEmpty { Text("决定：" + r.decision).font(.caption12).foregroundStyle(Theme.accent) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption12)
        }
    }
}

// MARK: - 已确定

private struct ConfirmedPanel: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var harmony: HarmonyRevision
    @ViewState private var transport = TransportModel()
    @ViewState private var originalGain = Double(AppModel.playAlongOriginalGain)

    private var playing: Bool { transport.isPlaying && model.playAlongItem == item.id }
    /// Clip time of the playhead while the original + chords play.
    private var clipUs: Int64 { Int64(Double(transport.positionFrame) / item.source.sampleRate * 1e6) - item.trimStartUs }
    private var soundingId: String? {
        guard playing else { return nil }
        let t = clipUs
        return model.playAlongSpans.last { $0.startUs <= t && $0.endUs > t }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("完整进行").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    if playing { model.stopPlayAlong() } else { model.playAlong(item.id, harmony: harmony) }
                } label: { Label(playing ? "停止" : "播放原曲和和弦", systemImage: playing ? "stop.fill" : "play.fill") }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                HStack(spacing: 4) {
                    Image(systemName: originalGain == 0 ? "speaker.slash" : "speaker.wave.2").font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Slider(value: $originalGain, in: 0...1).frame(width: 90)
                        .onChange(of: originalGain) { _, g in model.setPlayAlongOriginalGain(Float(g)) }
                }
                .help("原曲音量（和弦音量不变）")
                Button("修改") { model.stopPlayAlong(); model.beginEditing(item.id) }.buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("打开核对：改完点确定才生效")
            }
            Text(harmony.events.map { ($0.symbol ?? "未确定") }.joined(separator: "  →  ")).font(.system(size: 15, weight: .medium)).textSelection(.enabled)
            if let g = HarmonySection.grid(item, harmony) {
                BarProgressionView(item: item, harmony: harmony, auto: harmony.auto, grid: g, playingId: soundingId,
                                   onBarTap: { bar in model.playAlong(item.id, harmony: harmony, fromUs: max(0, BarEvidence.barStartUs(bar, grid: g))) })
            }
        }
        .onAppear { transport.sampleRate = item.source.sampleRate }
        .onDisappear { if model.playAlongItem == item.id { model.stopPlayAlong() }; transport.stop() }
    }
}
