import MusicnoteCore
import MusicnotePractice
import SwiftUI
import UniformTypeIdentifiers

/// 练琴: what a clip needs before practising — its files out to Logic for calibrating the
/// MIDI by hand, the calibrated MIDI back in, and the backing without the selected stem.
struct PracticeSetupStage: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem

    @ViewState private var exporting = false
    @ViewState private var exported: URL?
    @ViewState private var pending: PracticeImportPreview?
    @ViewState private var lastImport: String?
    @ViewState private var dropTargeted = false

    var body: some View {
        let takes = model.practiceTakes(item.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                toLogic
                fromLogic(takes)
                backing
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
        }
    }

    // MARK: To Logic

    private var toLogic: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "1　送到 Logic 校准",
                              subtitle: "导出一个文件夹：原曲片段、\(item.stemLabel.isEmpty ? "分轨" : item.stemLabel)分轨和 MIDI。三个文件从同一时刻开始，MIDI 里带着确认过的速度。")
                VStack(alignment: .leading, spacing: 4) {
                    step("把三个文件一起拖到 Logic 第 1 小节的开头，问是否导入速度时选「导入」。")
                    step("对照分轨改 MIDI。不要移动音频片段的位置。")
                    step("选中 MIDI 片段，用「文件 › 导出 › 所选内容为 MIDI 文件」导出，再拖回下面。")
                }
                HStack(spacing: 10) {
                    Button {
                        exporting = true
                        Task { exported = await model.exportLogicBundle(item.id); exporting = false }
                    } label: { Label("导出到 Logic…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(exporting || model.practiceNotes(item) == nil || item.timing == nil)
                    if exporting { ProgressView().controlSize(.small); Text("正在导出音频").font(.caption12).foregroundStyle(Theme.textSecondary) }
                    else if let exported {
                        Label("已导出到「\(exported.lastPathComponent)」", systemImage: "checkmark.circle").font(.caption12).foregroundStyle(Theme.success)
                    }
                    Spacer()
                    if let t = item.timing {
                        let pad = Double(-LogicRoundTrip.startUs(t)) / 1e6
                        Text(pad > 0.0005 ? "\(String(format: "%.1f", t.bpm)) BPM · 开头垫了 \(String(format: "%.2f", pad)) 秒静音，让 Logic 的小节线对上音乐"
                                          : "\(String(format: "%.1f", t.bpm)) BPM · 片段开头就是小节线")
                            .font(.caption12).foregroundStyle(Theme.textSecondary)
                    }
                }
                if model.practiceMidi(item.id) != nil {
                    Text("已有校准过的 MIDI，导出的是它，不是最初的转录。").font(.caption12).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func step(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("·").foregroundStyle(Theme.textSecondary)
            Text(text).font(.control13).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: From Logic

    private func fromLogic(_ takes: [PracticeMidi]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "2　放回校准后的 MIDI", subtitle: "把 Logic 导出的 .mid 拖到这里。会和转录结果比一下位置，整体错位时提醒你。")
                HStack(spacing: 10) {
                    Button { choose() } label: { Label("选择 MIDI 文件…", systemImage: "doc.badge.plus") }.buttonStyle(SecondaryButtonStyle())
                    if let lastImport { Label(lastImport, systemImage: "checkmark.circle").font(.caption12).foregroundStyle(Theme.success) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dropTargeted ? Theme.selectionFill : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(dropTargeted ? Theme.accent : Theme.controlBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: { ["mid", "midi"].contains($0.pathExtension.lowercased()) }) else { return false }
                    read(url); return true
                } isTargeted: { dropTargeted = $0 }

                if let p = pending { review(p) }

                if let current = takes.last {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("正在使用").font(.system(size: 13, weight: .semibold))
                        takeRow(current, current: true)
                        if takes.count > 1 {
                            Text("以前的版本").font(.system(size: 13, weight: .semibold)).padding(.top, 4)
                            ForEach(takes.dropLast().reversed()) { takeRow($0, current: false) }
                        }
                    }
                } else if pending == nil {
                    Text("还没有校准过的 MIDI，练琴时用的是转录结果。").font(.caption12).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func takeRow(_ take: PracticeMidi, current: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pianokeys").foregroundStyle(current ? Theme.accent : Theme.textSecondary)
            Text(take.fileName).font(.control13).lineLimit(1)
            Text("\(take.notes.count) 个音符" + (take.pedals.isEmpty ? "" : " · \(take.pedals.count) 次踏板"))
                .font(.caption12).foregroundStyle(Theme.textSecondary)
            Text(take.importedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption12).foregroundStyle(Theme.textSecondary)
            Spacer()
            Button(current ? "不用这一版" : "删除") { model.deletePracticeTake(take); lastImport = nil }
                .buttonStyle(.borderless).font(.caption12)
                .help(current ? "删掉这一版，回到上一版；没有上一版时用转录结果" : "删掉这个旧版本")
        }
    }

    /// A take that did not land on the transcription: say how far off, and let the user choose.
    private func review(_ p: PracticeImportPreview) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 6) {
                if let us = p.shiftUs {
                    Text("「\(p.fileName)」整体\(us > 0 ? "晚" : "早")了 \(shiftText(us))").font(.system(size: 13, weight: .semibold))
                    Text("\(p.report.matched) / \(p.report.total) 个音符在转录结果里都有同样错开的对应音。多半是导出时 MIDI 片段不在第 1 小节开头，或者音频在 Logic 里被移动过。")
                        .font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("移回去再导入") { accept(p, undoShift: true) }.buttonStyle(PrimaryButtonStyle())
                        Button("按原样导入") { accept(p, undoShift: false) }.buttonStyle(SecondaryButtonStyle())
                        Button("取消") { pending = nil }.buttonStyle(.borderless)
                    }
                } else {
                    Text("没法确认「\(p.fileName)」的位置").font(.system(size: 13, weight: .semibold))
                    Text("它和转录结果只有 \(p.report.matched) / \(p.report.total) 个音符对得上，可能不是这个片段的 MIDI，或者改动很大。")
                        .font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("照样导入") { accept(p, undoShift: false) }.buttonStyle(SecondaryButtonStyle())
                        Button("取消") { pending = nil }.buttonStyle(.borderless)
                    }
                }
            }
            Spacer()
        }
        .noticeBox()
    }

    private func shiftText(_ us: Int64) -> String {
        let sec = String(format: "%.2f 秒", abs(Double(us)) / 1e6)
        guard let t = item.timing else { return sec }
        let bars = abs(Double(us)) / (t.grid.beatUs * t.grid.meter.quarterBeatsPerBar)
        return abs(bars - bars.rounded()) < 0.05 && bars.rounded() >= 1 ? "\(Int(bars.rounded())) 小节（\(sec)）" : sec
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data, UTType(filenameExtension: "midi") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        read(url)
    }

    private func read(_ url: URL) {
        lastImport = nil
        guard let p = model.readPracticeMidi(item.id, url: url) else { pending = nil; return }
        if p.report.verdict == .aligned { accept(p, undoShift: false) } else { pending = p }
    }

    private func accept(_ p: PracticeImportPreview, undoShift: Bool) {
        pending = nil
        guard let take = model.savePracticeMidi(item.id, p, undoShift: undoShift) else { return }
        let dropped = p.take.notes.count - take.notes.count
        lastImport = "已导入 \(take.notes.count) 个音符" + (p.report.verdict == .aligned ? "，位置和转录一致" : undoShift ? "，已移回原位" : "")
            + (dropped > 0 ? "（\(dropped) 个在片段之外，没有导入）" : "")
    }

    // MARK: Backing

    private var backing: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "3　伴奏", subtitle: "练琴时可以配原曲、\(item.stemLabel.isEmpty ? "所选" : item.stemLabel)分轨，或者去掉\(item.stemLabel.isEmpty ? "所选分轨" : item.stemLabel)的伴奏。")
                if model.backingURL(item) != nil {
                    Label("去掉\(item.stemLabel)的伴奏已经存好", systemImage: "checkmark.circle").font(.control13).foregroundStyle(Theme.success)
                } else if model.jobs[item.id]?.type == .backing {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在重新拆轨并合成伴奏，进度在页面顶部").font(.caption12).foregroundStyle(Theme.textSecondary) }
                } else if item.separation?.candidatesDeleted == false {
                    Text("确认 MIDI 后会自动存一份。").font(.caption12).foregroundStyle(Theme.textSecondary)
                } else {
                    HStack(spacing: 10) {
                        Text("这个片段的其他分轨已经删掉了，要重新拆一次轨才能合成伴奏。已有的分轨、MIDI 和和声都不会动。")
                            .font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("重新拆轨生成伴奏") { model.rebuildBacking(item.id) }.buttonStyle(SecondaryButtonStyle(compact: true))
                            .disabled(model.jobs[item.id] != nil || !item.hasValidTiming)
                    }
                }
            }
        }
    }
}
