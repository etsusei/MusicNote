import MusicnoteCore
import SwiftUI

struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var refTitle = ""
    @ViewState private var refURL = ""
    @ViewState private var refSection = ""
    @ViewState private var refContent = ""

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("设置与存储").font(.pageTitle)

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "外观与音色")
                        Picker("主题", selection: Binding(get: { model.settings.theme }, set: { model.settings.theme = $0; model.saveSettings() })) {
                            Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                        }.pickerStyle(.segmented).frame(width: 260)
                        InstrumentPicker()
                        Text("试听音色：钢琴、电钢琴、吉他，所有页面共用。音源为 MuseScore General（MIT）。").font(.caption12).foregroundStyle(Theme.textSecondary)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "模型连接", subtitle: "使用你已订阅的官方客户端登录；本应用不保存密码或 token，不会自动改用按量 API。")
                        ForEach(model.providers.keys.sorted(), id: \.self) { id in
                            let s = model.providerStatus[id]
                            HStack {
                                Text(model.providers[id]!.displayName).frame(width: 110, alignment: .leading)
                                StatusPill(text: s?.state.display ?? "…", color: s?.state == .connected ? Theme.success : Theme.warning)
                                if let a = s?.account { Text(a).font(.caption12).foregroundStyle(Theme.textSecondary) }
                                if let q = s?.quotaNote { Text(q).font(.caption12).foregroundStyle(Theme.textSecondary) }
                                Spacer()
                                Button(s?.state == .connected ? "重新登录" : "连接") {
                                    Task { try? await model.providers[id]?.login(); await model.refreshProviders() }
                                }.buttonStyle(SecondaryButtonStyle(compact: true))
                            }
                        }
                        Divider()
                        Text("默认模型与推理强度（新会话和 LLM 骨架使用；聊天里还可以按会话单独改）").font(.caption12).foregroundStyle(Theme.textSecondary)
                        ForEach(model.providers.keys.sorted(), id: \.self) { id in
                            HStack {
                                Text(model.providers[id]!.displayName).frame(width: 110, alignment: .leading)
                                ModelEffortPicker(fixedProvider: id,
                                                  modelId: Binding(get: { model.settings.providerModels[id] },
                                                                   set: { model.settings.providerModels[id] = $0; model.saveSettings() }),
                                                  effort: Binding(get: { model.validEffort(id, model: model.settings.providerModels[id], effort: model.settings.providerEfforts[id]) },
                                                                  set: { model.settings.providerEfforts[id] = $0; model.saveSettings() }))
                                Spacer()
                            }
                        }
                        Picker("骨架默认使用", selection: Binding(get: { model.settings.defaultProvider }, set: { model.settings.defaultProvider = $0; model.saveSettings() })) {
                            ForEach(model.providers.keys.sorted(), id: \.self) { Text(model.providers[$0]!.displayName).tag($0) }
                        }.frame(width: 260)
                        Button("刷新状态") { Task { await model.refreshProviders() } }.buttonStyle(.borderless)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "工具路径", subtitle: "初版只在本机自用；路径集中在这里。")
                        let missing = model.settings.tools.missing()
                        if !missing.isEmpty { Text("缺少：" + missing.joined(separator: "、")).font(.caption12).foregroundStyle(Theme.error) }
                        pathField("ffmpeg", \.ffmpeg)
                        pathField("ffprobe", \.ffprobe)
                        pathField("Essentia Python", \.essentiaPython)
                        pathField("Musicpy Python", \.musicpyPython)
                        pathField("MuScriptor Python", \.muscriptorPython)
                        pathField("拆轨程序", \.separatorBinary)
                        pathField("音色库", \.soundFont)
                        pathField("Codex", \.codexBinary)
                        pathField("Claude Code", \.claudeBinary)
                        HStack {
                            Text("MuScriptor 模型").frame(width: 140, alignment: .leading)
                            Picker("", selection: Binding(get: { model.settings.tools.muscriptorModel }, set: { model.settings.tools.muscriptorModel = $0; model.saveSettings() })) {
                                Text("small").tag("small"); Text("medium（默认）").tag("medium"); Text("large").tag("large")
                            }.frame(width: 180)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "老师参考材料", subtitle: "只有粘贴了实际读取内容的条目才会提供给模型；仅有链接的标为「待读取」。")
                        ForEach(model.store.all(ReferenceMaterial.self)) { r in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(r.title) · \(r.section)").font(.control13)
                                    Text(r.sourceURL).font(.caption12).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                StatusPill(text: r.isRead ? "已读取 \(r.content.count) 字" : "待读取", color: r.isRead ? Theme.success : Theme.warning)
                                Button { try? model.store.delete(ReferenceMaterial.self, id: r.id); model.dataVersion += 1 } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                        }
                        TextField("标题，如 Open Music Theory", text: $refTitle).textFieldStyle(.roundedBorder)
                        TextField("来源 URL", text: $refURL).textFieldStyle(.roundedBorder)
                        TextField("章节", text: $refSection).textFieldStyle(.roundedBorder)
                        TextEditor(text: $refContent).frame(height: 80).overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.borderSubtle))
                        Button("添加参考条目") {
                            var r = ReferenceMaterial(title: refTitle, author: "", sourceURL: refURL, section: refSection, content: refContent)
                            if !refContent.isEmpty { r.retrievedAt = Date() }
                            try? model.store.save(r)
                            refTitle = ""; refURL = ""; refSection = ""; refContent = ""; model.dataVersion += 1
                        }.buttonStyle(SecondaryButtonStyle(compact: true)).disabled(refTitle.isEmpty)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "存储", subtitle: model.paths.root.path)
                        ForEach(model.storageSummary(), id: \.0) { name, bytes in
                            HStack { Text(name); Spacer(); Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.mono13) }
                        }
                        let pending = model.store.all(Job.self).filter { $0.status == .failed || $0.status == .interrupted }
                        if !pending.isEmpty {
                            Text("失败或中断的任务（保留了重试所需的文件）").font(.caption12).foregroundStyle(Theme.textSecondary)
                            ForEach(pending) { j in
                                HStack {
                                    Text("\(j.type.rawValue) · \(j.errorMessage ?? j.status.rawValue)").font(.caption12).lineLimit(1)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Pipeline.directorySize(model.paths.jobDirectory(j.id)), countStyle: .file)).font(.caption12)
                                    Button("丢弃任务") { model.discardJob(j) }.buttonStyle(.borderless).font(.caption12)
                                }
                            }
                        }
                        HStack {
                            Button("清理波形缓存") { model.paths.removeOwned(model.paths.waveformCache); try? model.paths.ensure(); model.dataVersion += 1 }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                            Button("整库备份…") { model.backupLibrary() }.buttonStyle(SecondaryButtonStyle(compact: true))
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.root]) }.buttonStyle(.borderless)
                        }
                        Text("完成的片段只保留选中分轨 MP3、校正 MIDI、分析和笔记；不保存原曲副本，也从不删除你的外部源文件。")
                            .font(.caption12).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
        }
    }

    private func pathField(_ label: String, _ kp: WritableKeyPath<ToolSettings, String>) -> some View {
        HStack {
            Text(label).frame(width: 140, alignment: .leading)
            TextField("", text: Binding(get: { model.settings.tools[keyPath: kp] }, set: { model.settings.tools[keyPath: kp] = $0 }))
                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                .onSubmit { model.saveSettings(); model.rebuildProviders() }
            Image(systemName: FileManager.default.fileExists(atPath: model.settings.tools[keyPath: kp]) ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(FileManager.default.fileExists(atPath: model.settings.tools[keyPath: kp]) ? Theme.success : Theme.error)
        }
    }
}

struct BookmarksPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let _ = model.dataVersion
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("收藏与高亮").font(.pageTitle)
                let marks = model.chat.allBookmarks()
                if marks.isEmpty { Text("在聊天回答里选中文字，右键「收藏到书签」。").foregroundStyle(Theme.textSecondary) }
                ForEach(marks) { h in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("“\(h.quotedText)”").font(.body14)
                            HStack {
                                Text(model.chat.conversations.first { $0.id == h.conversationId }?.title ?? "会话").font(.caption12).foregroundStyle(Theme.textSecondary)
                                Text(h.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption12).foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Button("回到原文") { model.chat.jump(to: h) }.buttonStyle(SecondaryButtonStyle(compact: true))
                                Button { model.chat.removeHighlight(h); model.dataVersion += 1 } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Text("学习收藏组合").font(.sectionTitle)
                ForEach(model.collections()) { c in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(c.title).font(.system(size: 14, weight: .medium))
                            FlowLayout(spacing: 6) {
                                ForEach(Array(c.items.enumerated()), id: \.offset) { _, it in
                                    Button(it.symbol) {
                                        AudioEngine.shared.playNotes(it.notes.map { (pitch: $0.pitch, start: $0.startQ * 0.5, duration: $0.durationQ * 0.5, velocity: $0.velocity) })
                                    }.buttonStyle(SecondaryButtonStyle(compact: true))
                                    .contextMenu { Button("回到来源") { model.route = .analysis(it.analysisId) } }
                                }
                            }
                            Text("收藏保存的是和弦材料本身；它和 @整段会话 是不同的对象。").font(.caption12).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
        }
    }
}
