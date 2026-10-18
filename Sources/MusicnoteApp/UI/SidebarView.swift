import MusicnoteCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var expanded: Set<UUID> = []
    @ViewState private var showTags = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    TextField("搜索歌名、歌手、笔记、标签", text: $model.search).textFieldStyle(.roundedBorder)
                    Menu {
                        Picker("排序", selection: $model.sortMode) { ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue) } }
                    } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).frame(width: 24).help("排序")
                }
                HStack(spacing: 6) {
                    Button { showTags.toggle() } label: { Label(model.tagFilter.isEmpty ? "标签筛选" : "标签 \(model.tagFilter.count)", systemImage: "tag") }
                        .buttonStyle(.borderless).font(.caption12)
                        .popover(isPresented: $showTags) { TagFilterPopover().environment(model) }
                    Spacer()
                    Button { model.addSong() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("新增歌曲")
                }
                if !model.tagFilter.isEmpty {
                    HStack {
                        Text("筛选：" + model.tagFilter.sorted().joined(separator: " 或 ")).font(.caption12).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        Spacer()
                        Button("清除") { model.tagFilter = [] }.buttonStyle(.borderless).font(.caption12)
                    }
                }
            }
            .padding(12)

            List {
                Section("歌曲") {
                    ForEach(model.visibleSongs) { song in
                        SongRow(song: song, expanded: expanded.contains(song.id)) {
                            if expanded.contains(song.id) { expanded.remove(song.id) } else { expanded.insert(song.id) }
                        }
                        .routeRow(.song(song.id))
                        .contextMenu {
                            Button("新增分析…") { model.addAnalysis(to: song) }
                            Button("删除歌曲", role: .destructive) { model.deleteSong(song) }
                        }
                        if expanded.contains(song.id) || model.isSelected(in: song) {
                            ForEach(model.items(of: song.id)) { item in
                                ItemRow(item: item).padding(.leading, 18).routeRow(.analysis(item.id))
                                    .contextMenu { Button("删除分析", role: .destructive) { model.deleteAnalysis(item) } }
                            }
                        }
                    }
                    .onMove { from, to in model.moveSongs(from: from, to: to) }
                }
                Section("Playground") {
                    ForEach(model.playgrounds) { p in
                        Label(p.title, systemImage: "square.grid.3x2").routeRow(.playground(p.id))
                            .contextMenu { Button("删除作品", role: .destructive) { model.deletePlayground(p) } }
                    }
                    Button { model.newPlayground() } label: { Label("新建作品", systemImage: "plus") }.buttonStyle(.borderless)
                }
                Section("灵感集合") {
                    Label("灵感集合（\(model.inspirationList.count)）", systemImage: "lightbulb").routeRow(.inspirations)
                }
                Section {
                    Label("收藏与高亮", systemImage: "bookmark").routeRow(.bookmarks)
                    Label("设置与存储", systemImage: "gearshape").routeRow(.settings)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.surface)
    }
}

extension AppModel {
    /// The song or one of its clips is open, so its clips are listed.
    func isSelected(in song: Song) -> Bool {
        if case .analysis(let id) = route { return items(of: song.id).contains { $0.id == id } }
        if case .song(let id) = route { return id == song.id }
        return false
    }

    func moveSongs(from: IndexSet, to: Int) {
        guard sortMode == .manual, search.isEmpty, tagFilter.isEmpty else { return }
        var list = visibleSongs
        list.move(fromOffsets: from, toOffset: to)
        for (i, var s) in list.enumerated() { s.sortIndex = Double(i); try? store.save(s) }
        reload()
    }
}

struct SongRow: View {
    @Environment(AppModel.self) private var model
    var song: Song
    var expanded: Bool
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10)) }
                .buttonStyle(.borderless).frame(width: 12)
            CoverView(song: song, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(song.artist.isEmpty ? "\(model.items(of: song.id).count) 个片段" : song.artist).font(.caption12)
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    var item: AnalysisItem
    var body: some View {
        HStack(spacing: 6) {
            if model.jobs[item.id] != nil { ProgressView().controlSize(.mini) } else {
                Circle().fill(item.state == .ready ? Theme.success : Theme.textSecondary.opacity(0.5)).frame(width: 6, height: 6)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.control13).lineLimit(1)
                Text("\(formatTime(us: item.trimStartUs, millis: false))–\(formatTime(us: item.trimEndUs, millis: false)) · \(item.state.display)")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct CoverView: View {
    @Environment(AppModel.self) private var model
    var song: Song
    var size: CGFloat
    var body: some View {
        Group {
            if let f = song.coverFile, let img = NSImage(contentsOf: model.paths.covers.appendingPathComponent(f)) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack { Theme.selectionFill; Image(systemName: "music.note").foregroundStyle(Theme.accent) }
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct TagFilterPopover: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("按手动标签筛选（任一匹配）").font(.caption12).foregroundStyle(Theme.textSecondary)
            if model.allTags.isEmpty { Text("还没有标签").font(.control13) }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(model.allTags, id: \.self) { tag in
                        Toggle(tag, isOn: Binding(get: { model.tagFilter.contains(tag) },
                                                  set: { on in if on { model.tagFilter.insert(tag) } else { model.tagFilter.remove(tag) } }))
                    }
                }
            }.frame(maxHeight: 260)
        }
        .padding(12).frame(width: 240)
    }
}

/// Sidebar rows draw their own selection so text stays readable in both themes.
private struct RouteRow: ViewModifier {
    @Environment(AppModel.self) private var model
    var route: Route
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.route = route }
            .listRowBackground(RoundedRectangle(cornerRadius: 6).fill(model.route == route ? Theme.selectionFill : Color.clear).padding(.horizontal, 6))
    }
}

extension View {
    func routeRow(_ route: Route) -> some View { modifier(RouteRow(route: route)) }
}
