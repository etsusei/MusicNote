import Foundation

/// A site songs can be imported from by pasting a link.
public enum LinkSite: String, Sendable {
    case instagram, youtube
    public var display: String {
        switch self { case .instagram: "Instagram"; case .youtube: "YouTube" }
    }
}

/// A recognised link, on its canonical address.
public struct MediaLink: Hashable, Sendable {
    public var site: LinkSite
    public var url: URL
}

/// A downloaded video, ready to become a song.
public struct LinkMedia: Sendable {
    public var audio: URL
    public var mediaId: String
    public var title: String
    public var artist: String
    public var artwork: Data?
}

/// Importing a link: yt-dlp fetches the video's audio stream (or the whole video when it has none
/// of its own), and that goes through the video import like a local file would.
extension Pipeline {
    /// The Instagram post or YouTube video linked in pasted text, on its canonical address (no
    /// tracking query, playlist or m. host). An Instagram share link stays as it is, since only
    /// Instagram knows what it points to.
    public static func mediaLink(in text: String) -> MediaLink? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: whole) {
            guard let url = match.url else { continue }
            if let link = canonicalInstagramLink(url) { return MediaLink(site: .instagram, url: link) }
            if let link = canonicalYouTubeLink(url) { return MediaLink(site: .youtube, url: link) }
        }
        return nil
    }

    private static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func canonicalInstagramLink(_ url: URL) -> URL? {
        let hosts: Set<String> = ["instagram.com", "www.instagram.com", "m.instagram.com", "instagr.am", "www.instagr.am"]
        guard let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        func isCode(_ s: String) -> Bool { s != "audio" && isToken(s) }
        func address(_ path: [String]) -> URL? { URL(string: "https://www.instagram.com/" + path.joined(separator: "/") + "/") }
        let kinds: Set<String> = ["p", "reel", "reels", "tv"]
        if parts.first == "share" {
            // /share/<token> or /share/<kind>/<token>
            if parts.count == 2, isCode(parts[1]) { return address(parts) }
            if parts.count == 3, kinds.contains(parts[1]), isCode(parts[2]) { return address(parts) }
            return nil
        }
        // /<kind>/<code> or /<user>/<kind>/<code>
        for start in 0...1 where parts.count > start + 1 && kinds.contains(parts[start]) && isCode(parts[start + 1]) {
            return address([parts[start], parts[start + 1]])
        }
        return nil
    }

    /// watch?v=, youtu.be/, shorts/, live/ and embed/ all name one video by its 11-character id.
    private static func canonicalYouTubeLink(_ url: URL) -> URL? {
        let hosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"]
        guard let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        var id: String?
        if host.hasSuffix("youtu.be") {
            id = parts.first
        } else if parts == ["watch"] {
            id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        } else if parts.count >= 2, ["shorts", "live", "embed", "v"].contains(parts[0]) {
            id = parts[1]
        }
        guard let id, id.count == 11, isToken(id) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=" + id)
    }

    /// Where an Instagram share link leads. yt-dlp doesn't take share links, so Instagram is asked first.
    private static func resolveInstagramShare(_ link: URL) async throws -> URL {
        var request = URLRequest(url: link, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let failure = WorkerError(code: "INSTAGRAM_LINK", message: "这个分享链接解析不出来。请在浏览器里打开它，再复制地址栏里的链接。", retryable: false)
        guard let response = try? await URLSession.shared.data(for: request).1, let target = response.url else { throw failure }
        var candidates = [target]
        // Logged-out visitors can land on the login page, with the post in `next`.
        if let next = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "next" })?.value,
           let nextURL = URL(string: next, relativeTo: target)?.absoluteURL { candidates.append(nextURL) }
        for candidate in candidates {
            if let resolved = canonicalInstagramLink(candidate), !resolved.path.hasPrefix("/share") { return resolved }
        }
        throw failure
    }

    /// Downloads the linked video (the first one of an Instagram post) and extracts its audio into the library.
    public func downloadLink(_ link: MediaLink) async throws -> LinkMedia {
        guard FileManager.default.isExecutableFile(atPath: tools.ytDlp) else {
            throw WorkerError(code: "YTDLP_MISSING", message: "找不到 yt-dlp。用 brew install yt-dlp 安装，或在设置的工具路径里改位置。", retryable: false)
        }
        // YouTube only serves its formats to a client that runs its JavaScript; yt-dlp uses deno for that.
        if link.site == .youtube, !FileManager.default.isExecutableFile(atPath: tools.deno) {
            throw WorkerError(code: "DENO_MISSING", message: "下载 YouTube 需要 deno。用 brew install deno 安装，或在设置的工具路径里改位置。", retryable: false)
        }
        var target = link.url
        if link.site == .instagram, target.path.hasPrefix("/share") { target = try await Self.resolveInstagramShare(target) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicnote-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var args = ["--ignore-config", "--no-warnings", "--no-progress", "--playlist-items", "1", "-f", "bestaudio/best",
                    "--write-thumbnail", "--convert-thumbnails", "jpg", "--ffmpeg-location", tools.ffmpeg,
                    "-P", dir.path, "-o", "\(link.site.rawValue)-%(id)s.%(ext)s",
                    "--print", "after_move:%(.{id,title,uploader,channel,artist,track,description,filepath})j"]
        if link.site == .youtube { args += ["--js-runtimes", "deno:" + tools.deno] }
        if let browser = tools.ytDlpCookiesBrowser { args += ["--cookies-from-browser", browser] }
        args += ["--", target.absoluteString]

        nonisolated(unsafe) var info: [String: Any]?
        let r = try await WorkerProcess(tools.ytDlp, args).run { if let m = decodeJSONLine($0) { info = m } }
        guard r.status == 0, let info, let path = info["filepath"] as? String else {
            throw Self.linkFailure(stderr: r.stderr, site: link.site, browser: tools.ytDlpCookiesBrowser)
        }
        let file = URL(fileURLWithPath: path)
        let audio = try await extractVideoAudio(file)
        let uploader = (info["uploader"] as? String) ?? (info["channel"] as? String) ?? ""
        let named: (title: String, artist: String)
        switch link.site {
        case .instagram:
            named = (Self.instagramTitle(caption: info["description"] as? String, owner: uploader), uploader.precomposedStringWithCanonicalMapping)
        case .youtube:
            named = Self.youtubeNames(title: info["title"] as? String ?? "", uploader: uploader,
                                      track: info["track"] as? String, artist: info["artist"] as? String)
        }
        return LinkMedia(audio: audio, mediaId: info["id"] as? String ?? file.deletingPathExtension().lastPathComponent,
                         title: named.title, artist: named.artist,
                         artwork: try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("jpg")))
    }

    /// The caption's first line with words to say (hashtags and mentions don't count), since the
    /// title Instagram reports is only "Video by <user>".
    public static func instagramTitle(caption: String?, owner: String) -> String {
        for line in (caption ?? "").split(whereSeparator: \.isNewline) {
            let text = line.replacingOccurrences(of: "[#@]\\S+", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let clean = text.precomposedStringWithCanonicalMapping
            return clean.count > 40 ? clean.prefix(40) + "…" : clean
        }
        return owner.isEmpty ? "Instagram 视频" : "\(owner.precomposedStringWithCanonicalMapping) 的 Instagram 视频"
    }

    /// Song title and artist of a YouTube video: the music metadata when YouTube has it; otherwise
    /// "Artist - Title" split apart, without "(Official Video)" and the like; otherwise the video
    /// title and the channel (an auto-generated "<artist> - Topic" channel is named by its artist).
    public static func youtubeNames(title: String, uploader: String, track: String?, artist: String?) -> (title: String, artist: String) {
        func clean(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces) }
        let channel = clean(uploader.hasSuffix(" - Topic") ? String(uploader.dropLast(8)) : uploader)
        if let track, !track.isEmpty { return (clean(track), clean(artist ?? "").isEmpty ? channel : clean(artist!)) }
        var name = clean(title)
        // Labels that describe the upload rather than the song, in brackets of any kind.
        let label = "(?i)\\s*[\\(\\[【（][^\\)\\]】）]*(official|video|audio|lyric|mv|m/v|4k|hd|remaster|visuali[sz]er|官方|歌词|歌詞|高清|完整版)[^\\)\\]】）]*[\\)\\]】）]"
        name = clean(name.replacingOccurrences(of: label, with: "", options: .regularExpression))
        for dash in [" - ", " – ", " — "] {
            if let r = name.range(of: dash) {
                let left = clean(String(name[..<r.lowerBound])), right = clean(String(name[r.upperBound...]))
                if !left.isEmpty, !right.isEmpty { return (right, left) }
            }
        }
        return (name.isEmpty ? clean(title) : name, channel)
    }

    /// What went wrong, in terms of what the user can do about it.
    public static func linkFailure(stderr: String, site: LinkSite, browser: String?) -> WorkerError {
        let line = stderr.split(whereSeparator: \.isNewline).last { $0.contains("ERROR:") }.map(String.init) ?? String(stderr.suffix(300))
        let low = stderr.lowercased().replacingOccurrences(of: "’", with: "'")
        func has(_ words: String...) -> Bool { words.contains { low.contains($0) } }
        let name = site.display
        // Login failures also mention --cookies-from-browser, so a browser problem is told apart by these.
        if let browser, has("cookies database", "operation not permitted") {
            return WorkerError(code: "LINK_COOKIES", message: "读不到 \(browser) 的登录信息。确认装了这个浏览器；Safari 还要在系统设置里给 Musicnote 开“完全磁盘访问权限”。", retryable: false)
        }
        if has("no video in this post", "no video formats") {
            return WorkerError(code: "LINK_NO_VIDEO", message: "这条帖子只有图片，没有视频。", retryable: false)
        }
        if has("timed out", "failed to resolve", "nodename nor servname", "network is unreachable", "connection refused", "connection reset") {
            return WorkerError(code: "LINK_NETWORK", message: "连不上 \(name)，检查网络后再试。")
        }
        if has("live event will begin", "premieres in", "is upcoming") {
            return WorkerError(code: "LINK_UPCOMING", message: "这个视频还没开始（预告的直播或首映），开始后再导入。", retryable: false)
        }
        if has("members-only", "join this channel") {
            return WorkerError(code: "LINK_MEMBERS", message: "这是频道会员专属的视频。", retryable: false)
        }
        let loginWords = site == .youtube
            ? ["sign in", "private video", "login", "log in", "--cookies"]
            : ["log in", "login", "rate-limit", "rate limit", "empty media response", "private", "not available", "--cookies"]
        if loginWords.contains(where: { low.contains($0) }) {
            let why = site == .youtube ? "YouTube 要求登录（私密、有年龄限制，或怀疑是机器人）。" : "Instagram 不给这条内容：可能已删除、是私密账号，或需要登录。"
            let hint = browser.map { "请确认 \($0) 已登录 \(name)，且这个账号能看到这条内容。" } ?? "如果在浏览器里能打开，可以在设置的工具路径里选一个已登录 \(name) 的浏览器，再试一次。"
            return WorkerError(code: "LINK_LOGIN", message: why + hint)
        }
        if has("video unavailable", "video is unavailable", "has been removed", "no longer available", "does not exist") {
            return WorkerError(code: "LINK_UNAVAILABLE", message: "这个视频不存在或已下架。", retryable: false)
        }
        return WorkerError(code: "LINK_DOWNLOAD", message: "下载失败：\(line)\n如果一直这样，可能是 \(name) 改了接口，试试 brew upgrade yt-dlp。")
    }
}
