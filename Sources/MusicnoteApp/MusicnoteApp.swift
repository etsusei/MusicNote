import AppKit
import MusicnoteCore
import SwiftUI

struct MusicnoteApp: App {
    @ViewState private var model = AppModel()

    var body: some Scene {
        WindowGroup("Musicnote") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .tint(Theme.accent)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true); model.applyTheme(); DebugSnapshot.runIfRequested(model)
                    if ProcessInfo.processInfo.environment["MUSICNOTE_SNAPSHOT_DIR"] == nil { InspirationWindow.shared.restore(model) }
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新增歌曲…") { model.addSong() }.keyboardShortcut("n")
                Button("新建 Playground 作品") { model.newPlayground() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("新会话") { model.chat.newConversation(); model.showRight = true }.keyboardShortcut("t")
            }
            CommandMenu("视图") {
                Button(model.showLeft ? "收起左栏" : "展开左栏") { withAnimation(.easeInOut(duration: 0.16)) { model.showLeft.toggle() } }
                    .keyboardShortcut("[", modifiers: [.command])
                Button(model.showRight ? "收起聊天栏" : "展开聊天栏") { withAnimation(.easeInOut(duration: 0.16)) { model.showRight.toggle() } }
                    .keyboardShortcut("]", modifiers: [.command])
            }
            CommandMenu("播放") {
                Button("播放 / 暂停") { NotificationCenter.default.post(name: .togglePlayback, object: nil) }
                    .keyboardShortcut(.space, modifiers: [])
                Button("停止预览") { AudioEngine.shared.stopPreview(); AudioEngine.shared.stopChord() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}

extension Notification.Name {
    static let togglePlayback = Notification.Name("musicnote.togglePlayback")
}
