import Foundation

/// Where the app keeps its own data. Only paths under `root` are ever deleted.
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root { self.root = root } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("Musicnote", isDirectory: true)
        }
    }

    public var database: URL { root.appendingPathComponent("library.sqlite") }
    public var assets: URL { root.appendingPathComponent("assets", isDirectory: true) }
    public var jobs: URL { root.appendingPathComponent("jobs", isDirectory: true) }
    public var covers: URL { root.appendingPathComponent("covers", isDirectory: true) }
    public var waveformCache: URL { root.appendingPathComponent("cache/waveforms", isDirectory: true) }
    public var exports: URL { root.appendingPathComponent("exports", isDirectory: true) }
    public var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public var chatSandbox: URL { root.appendingPathComponent("chat-sandbox", isDirectory: true) }

    public func analysisAssets(_ id: UUID) -> URL { assets.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func jobDirectory(_ id: UUID) -> URL { jobs.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func url(relative: String) -> URL { root.appendingPathComponent(relative) }
    public func relative(_ url: URL) -> String {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    public func ensure() throws {
        for d in [root, assets, jobs, covers, waveformCache, exports, chatSandbox] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// Guard for every delete: the target must be inside the app's own data root.
    public func isOwned(_ url: URL) -> Bool {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(r + "/") && p != r
    }

    public func removeOwned(_ url: URL) {
        guard isOwned(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// External tools and model locations, editable in Settings. Defaults point at
/// this machine's installs.
public struct ToolSettings: Codable, Hashable, Sendable {
    public var projectRoot: String
    public var ffmpeg: String
    public var ffprobe: String
    public var systemPython: String
    public var essentiaPython: String
    public var musicpyPython: String
    public var muscriptorPython: String
    public var muscriptorModel: String
    public var muscriptorDevice: String
    public var separatorBinary: String
    public var soundFont: String
    public var codexBinary: String
    public var claudeBinary: String

    public static func defaults(projectRoot: String, separatorBinary: String) -> ToolSettings {
        ToolSettings(
            projectRoot: projectRoot,
            ffmpeg: "/opt/homebrew/bin/ffmpeg",
            ffprobe: "/opt/homebrew/bin/ffprobe",
            systemPython: "/usr/bin/python3",
            essentiaPython: projectRoot + "/workers/essentia/.venv/bin/python",
            musicpyPython: projectRoot + "/workers/musicpy/.venv/bin/python",
            muscriptorPython: projectRoot + "/muscriptor/.venv/bin/python",
            muscriptorModel: "medium",
            muscriptorDevice: "mps",
            separatorBinary: separatorBinary,
            soundFont: projectRoot + "/Resources/SoundFonts/MuseScore_General.sf2",
            codexBinary: "/opt/homebrew/bin/codex",
            claudeBinary: "/opt/homebrew/bin/claude")
    }

    public var workers: String { projectRoot + "/workers" }

    public func missing() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for (name, path) in [("ffmpeg", ffmpeg), ("ffprobe", ffprobe), ("Python", systemPython),
                             ("Essentia", essentiaPython), ("Musicpy", musicpyPython), ("MuScriptor", muscriptorPython),
                             ("拆轨程序", separatorBinary), ("音色库", soundFont)] where !fm.fileExists(atPath: path) {
            out.append(name)
        }
        return out
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var tools: ToolSettings
    public var instrument: Instrument
    public var theme: String // system / light / dark
    public var defaultProvider: String
    public var providerModels: [String: String]
    public var providerEfforts: [String: String]

    public init(tools: ToolSettings) {
        self.tools = tools; instrument = .piano; theme = "system"; defaultProvider = "codex"
        providerModels = [:]; providerEfforts = [:]
    }

    public static func load(_ paths: AppPaths, defaults: ToolSettings) -> AppSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings(tools: defaults) }
        return s
    }

    public func save(_ paths: AppPaths) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: paths.settingsFile, options: .atomic)
    }
}

public enum Instrument: String, Codable, CaseIterable, Sendable {
    case piano, electricPiano, guitar
    public var display: String {
        switch self { case .piano: "钢琴"; case .electricPiano: "电钢琴"; case .guitar: "吉他" }
    }
    /// General MIDI program in the SoundFont.
    public var program: UInt8 {
        switch self { case .piano: 0; case .electricPiano: 4; case .guitar: 26 }
    }
}
