import MusicnoteCore
import SwiftUI

/// Paste an Instagram or YouTube link; the download runs after the sheet closes, shown in the toolbar.
struct LinkImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ViewState private var text = ""
    @ViewState private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("从链接新增歌曲").font(.sectionTitle)
            Text("粘贴 Instagram 帖子、Reels 或 YouTube 视频、Shorts 的链接，下载音频后就和本地原曲一样圈片段、往下走。多视频的帖子取第一条，播放列表里的只取这一个视频。")
                .font(.caption12).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            TextField("粘贴 Instagram 或 YouTube 链接", text: $text).textFieldStyle(.roundedBorder).focused($focused)
                .onChange(of: text) { invalid = false }
            if invalid { Text("没认出来。需要 Instagram 帖子或 Reels、YouTube 视频或 Shorts 的链接；主页、快拍和整个播放列表不行。").font(.caption12).foregroundStyle(Theme.warning) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("下载") { submit() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { focused = true }
    }

    private func submit() {
        guard let link = Pipeline.mediaLink(in: text) else { invalid = true; return }
        dismiss()
        Task { await model.createSong(fromLink: link) }
    }
}
