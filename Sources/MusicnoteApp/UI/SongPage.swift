import MusicnoteCore
import SwiftUI
import UniformTypeIdentifiers

struct SongPage: View {
    @Environment(AppModel.self) private var model
    @ViewState var song: Song
    @ViewState private var newTag = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    CoverView(song: song, size: 120)
                        .onTapGesture { pickCover() }
                        .help("点击从图片导入封面")
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("歌名", text: $song.title).font(.pageTitle).textFieldStyle(.plain)
                        TextField("歌手", text: $song.artist).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        TextField("专辑", text: $song.album).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        TagEditor(tags: $song.tags, placeholder: "添加歌曲标签")
                    }
                }
                .onChange(of: song) { _, s in model.save(s) }

                HStack {
                    SectionHeader(title: "分析子项", subtitle: "每个子项只分析一个连续片段；新增分析需要重新选择本地原曲。")
                    Spacer()
                    Button("新增分析…") { model.addAnalysis(to: song) }.buttonStyle(PrimaryButtonStyle())
                }
                let items = model.items(of: song.id)
                if items.isEmpty {
                    Card { Text("还没有分析子项。点「新增分析」选择本地音频，再圈出想学的片段。").foregroundStyle(Theme.textSecondary) }
                }
                ForEach(items) { item in
                    Button { model.route = .analysis(item.id) } label: {
                        Card {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.system(size: 14, weight: .medium))
                                    Text("\(formatTime(us: item.trimStartUs))–\(formatTime(us: item.trimEndUs)) · \(item.source.fileName)")
                                        .font(.caption12).foregroundStyle(Theme.textSecondary)
                                    HStack(spacing: 6) {
                                        StatusPill(text: item.state.display, color: item.state == .ready ? Theme.success : Theme.textSecondary)
                                        if let t = item.timing { StatusPill(text: "\(t.key.display) · \(String(format: "%.1f", t.bpm)) BPM") }
                                        if let s = item.selectedStem { StatusPill(text: s.displayName) }
                                        ForEach(item.skeletonTags, id: \.self) { StatusPill(text: $0, color: Theme.accent) }
                                    }
                                }
                                Spacer()
                                if let h = model.latestHarmony(item.id) {
                                    Text(h.events.prefix(6).map { $0.symbol ?? "?" }.joined(separator: " → "))
                                        .font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                }
                                Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            .padding(24)
        }
    }

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let name = song.id.uuidString + "-" + UUID().uuidString.prefix(6) + "." + url.pathExtension
        try? data.write(to: model.paths.covers.appendingPathComponent(name))
        if let old = song.coverFile { model.paths.removeOwned(model.paths.covers.appendingPathComponent(old)) }
        song.coverFile = name
    }
}

/// Tags are typed and saved by the user only; display keeps the original text.
struct TagEditor: View {
    @Binding var tags: [String]
    var placeholder: String
    @ViewState private var text = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { t in
                HStack(spacing: 3) {
                    Text(t).font(.caption12)
                    Button { tags.removeAll { $0 == t } } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.selectionFill))
            }
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.caption12).frame(width: 140)
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty, !tags.contains(where: { TagText.normalize($0) == TagText.normalize(t) }) { tags.append(t) }
                    text = ""
                }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += lineH + spacing; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
        return CGSize(width: width, height: y + lineH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += lineH + spacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}
