import MusicnoteCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("leftWidth") private var leftWidth: Double = 240
    @AppStorage("rightWidth") private var rightWidth: Double = 360
    @ViewState private var rightAutoCollapsed = false

    private let minMain: Double = 560

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let total = geo.size.width
            let left = model.showLeft ? leftWidth : 0
            let wantsRight = model.showRight
            // Keep the main area usable: temporarily fold the chat column, with an explicit restore.
            let rightFits = total - left - rightWidth >= minMain
            let showRight = wantsRight && rightFits
            HStack(spacing: 0) {
                if model.showLeft {
                    SidebarView().frame(width: leftWidth)
                        .transition(.move(edge: .leading))
                    ResizeHandle(width: $leftWidth, range: 200...320, inverted: false)
                }
                MainView()
                    .frame(minWidth: minMain, maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if wantsRight && !rightFits {
                            Button { model.showLeft = false } label: { Label("聊天栏已因宽度暂时折叠，点此收起左栏恢复", systemImage: "bubble.right") }
                                .buttonStyle(SecondaryButtonStyle(compact: true)).padding(8)
                        }
                    }
                if showRight {
                    ResizeHandle(width: $rightWidth, range: 300...480, inverted: true)
                    ChatPanel().frame(width: rightWidth).clipped()
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation(.easeInOut(duration: 0.16)) { model.showLeft.toggle() } } label: {
                    Image(systemName: "sidebar.left")
                }.help(model.showLeft ? "收起左栏" : "展开左栏")
            }
            ToolbarItem(placement: .principal) { JobStatusBar() }
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation(.easeInOut(duration: 0.16)) { model.showRight.toggle() } } label: {
                    Image(systemName: "sidebar.right")
                }.help(model.showRight ? "收起聊天栏" : "展开聊天栏")
            }
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message + (a.code.map { "\n（\($0)）" } ?? "")), dismissButton: .default(Text("好")))
        }
    }
}

struct ResizeHandle: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    var inverted: Bool
    @ViewState private var start: Double?

    var body: some View {
        Rectangle().fill(Theme.borderSubtle).frame(width: 1)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    if start == nil { start = width }
                    let d = inverted ? -v.translation.width : v.translation.width
                    width = min(range.upperBound, max(range.lowerBound, (start ?? width) + d))
                }.onEnded { _ in start = nil }))
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.route {
            // SongPage keeps the song in @State; a new identity per song makes switching songs reload it.
            case .song(let id): if let s = model.song(id) { SongPage(song: s).id(id) } else { EmptyState() }
            case .analysis(let id): if model.item(id) != nil { AnalysisPage(itemId: id).id(id) } else { EmptyState() }
            case .playground(let id): if let p = model.playgrounds.first(where: { $0.id == id }) { PlaygroundPage(project: p).id(id) } else { EmptyState() }
            case .settings: SettingsPage()
            case .bookmarks: BookmarksPage()
            case .inspirations: InspirationCollectionPage()
            case nil: EmptyState()
            }
        }
        .background(Theme.background)
        .overlay(alignment: .bottomTrailing) { InspirationButton() }
    }
}

struct EmptyState: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list").font(.system(size: 40)).foregroundStyle(Theme.textSecondary)
            Text(model.songs.isEmpty ? "从一首喜欢的歌开始" : "从左栏选择歌曲或片段").font(.sectionTitle)
            Text("选择本地原曲，圈出想学的片段，确认速度调性后拆轨、转 MIDI、看和弦。")
                .font(.body14).foregroundStyle(Theme.textSecondary)
            Button("新增歌曲…") { model.addSong() }.buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Toolbar summary of running work; never invents a percentage.
struct JobStatusBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let s = model.importStatus {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(s).font(.caption12).lineLimit(1) }
        } else if let (id, j) = model.jobs.first {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.item(id)?.title ?? "").font(.caption12).foregroundStyle(Theme.textSecondary)
                Text(j.stage + (j.total.map { " \(j.completed)/\($0)" } ?? "")).font(.caption12)
            }
        }
    }
}
