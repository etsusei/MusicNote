import Foundation

/// A Standard MIDI File read back in: the notes and sustain pedal of every track, with the
/// file's own tempo map to turn ticks into seconds. Reads what Logic exports (format 0 or 1,
/// ticks per quarter note); SMPTE time division is not supported.
public struct MidiFileContents: Sendable {
    public struct Note: Hashable, Sendable {
        public var pitch: Int
        public var velocity: Int
        public var startTick: Int
        public var endTick: Int
        public var channel: Int
    }

    public struct Pedal: Hashable, Sendable {
        public var tick: Int
        public var down: Bool
    }

    public struct Track: Sendable {
        public var name: String?
        public var notes: [Note] = []
        public var pedals: [Pedal] = []
    }

    public var ppq: Int
    /// Tempo changes as (tick, microseconds per quarter note), sorted, the first at tick 0.
    public var tempos: [(tick: Int, mpq: Int)]
    public var tracks: [Track]

    /// Seconds from the start of the file at a tick, through every tempo change before it.
    public func seconds(atTick tick: Int) -> Double {
        var sec = 0.0
        var lastTick = 0, mpq = 500_000
        for t in tempos {
            if t.tick >= tick { break }
            sec += Double(t.tick - lastTick) * Double(mpq) / Double(ppq) / 1_000_000
            lastTick = t.tick; mpq = t.mpq
        }
        return sec + Double(tick - lastTick) * Double(mpq) / Double(ppq) / 1_000_000
    }

    /// The tempo at the start of the file, in quarter notes per minute.
    public var initialBpm: Double { 60_000_000 / Double(tempos.first?.mpq ?? 500_000) }
}

public enum MidiFileError: Error, LocalizedError, Equatable {
    case notMidi, smpteDivision, truncated

    public var errorDescription: String? {
        switch self {
        case .notMidi: "这不是标准 MIDI 文件"
        case .smpteDivision: "这个 MIDI 文件用的是时间码计时，读不了。请在 Logic 里用「导出所选内容为 MIDI 文件」重新导出"
        case .truncated: "MIDI 文件不完整"
        }
    }
}

public enum MidiFileReader {
    public static func read(_ data: Data) throws -> MidiFileContents {
        var r = Cursor(bytes: [UInt8](data))
        guard try r.tag() == "MThd" else { throw MidiFileError.notMidi }
        let headerLength = try r.u32()
        guard headerLength >= 6 else { throw MidiFileError.notMidi }
        _ = try r.u16() // format
        let trackCount = try r.u16()
        let division = try r.u16()
        guard division & 0x8000 == 0, division > 0 else { throw MidiFileError.smpteDivision }
        try r.skip(headerLength - 6)

        var tempos: [(tick: Int, mpq: Int)] = []
        var tracks: [MidiFileContents.Track] = []
        for _ in 0..<trackCount {
            // Chunks that are not tracks are skipped, as the format asks.
            var tag = try r.tag(), length = try r.u32()
            while tag != "MTrk" { try r.skip(length); tag = try r.tag(); length = try r.u32() }
            let end = r.at + length
            guard end <= r.bytes.count else { throw MidiFileError.truncated }
            var track = MidiFileContents.Track()
            var tick = 0
            var status: UInt8 = 0
            // Held notes per (channel, pitch), oldest first: a repeated note closes the earliest.
            var open: [Int: [(tick: Int, velocity: Int)]] = [:]
            func close(_ channel: Int, _ pitch: Int, at t: Int) {
                let k = channel << 8 | pitch
                guard var held = open[k], !held.isEmpty else { return }
                let first = held.removeFirst()
                open[k] = held
                if t > first.tick {
                    track.notes.append(.init(pitch: pitch, velocity: first.velocity, startTick: first.tick, endTick: t, channel: channel))
                }
            }
            while r.at < end {
                tick += try r.vlq()
                var b = try r.u8()
                if b < 0x80 {
                    // Running status: this byte is already the first data byte.
                    guard status >= 0x80 else { throw MidiFileError.truncated }
                    r.at -= 1
                    b = status
                } else if b < 0xF0 {
                    status = b
                }
                switch b {
                case 0xFF:
                    let type = try r.u8(), length = try r.vlq()
                    let body = try r.take(length)
                    if type == 0x51, body.count == 3 {
                        tempos.append((tick, Int(body[0]) << 16 | Int(body[1]) << 8 | Int(body[2])))
                    } else if type == 0x03, track.name == nil {
                        track.name = String(decoding: body, as: UTF8.self)
                    }
                case 0xF0, 0xF7:
                    try r.skip(try r.vlq())
                default:
                    let kind = b & 0xF0, channel = Int(b & 0x0F)
                    switch kind {
                    case 0x90:
                        let pitch = Int(try r.u8()), velocity = Int(try r.u8())
                        if velocity == 0 { close(channel, pitch, at: tick) } else {
                            open[channel << 8 | pitch, default: []].append((tick, velocity))
                        }
                    case 0x80:
                        let pitch = Int(try r.u8()); _ = try r.u8()
                        close(channel, pitch, at: tick)
                    case 0xB0:
                        let controller = try r.u8(), value = try r.u8()
                        if controller == 64 {
                            let down = value >= 64
                            if track.pedals.last?.down != down { track.pedals.append(.init(tick: tick, down: down)) }
                        }
                    case 0xA0, 0xE0: try r.skip(2)
                    case 0xC0, 0xD0: try r.skip(1)
                    default: throw MidiFileError.truncated
                    }
                }
            }
            // A note still held at the end of the track ends there.
            for (k, held) in open {
                for h in held where tick > h.tick {
                    track.notes.append(.init(pitch: k & 0xFF, velocity: h.velocity, startTick: h.tick, endTick: tick, channel: k >> 8))
                }
            }
            track.notes.sort { ($0.startTick, $0.pitch) < ($1.startTick, $1.pitch) }
            r.at = end
            tracks.append(track)
        }
        tempos.sort { $0.tick < $1.tick }
        if tempos.first?.tick != 0 { tempos.insert((0, tempos.first?.mpq ?? 500_000), at: 0) }
        return MidiFileContents(ppq: division, tempos: tempos, tracks: tracks)
    }

    private struct Cursor {
        var bytes: [UInt8]
        var at = 0

        mutating func u8() throws -> UInt8 {
            guard at < bytes.count else { throw MidiFileError.truncated }
            defer { at += 1 }
            return bytes[at]
        }
        mutating func u16() throws -> Int { Int(try u8()) << 8 | Int(try u8()) }
        mutating func u32() throws -> Int { try u16() << 16 | (try u16()) }
        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, at + n <= bytes.count else { throw MidiFileError.truncated }
            defer { at += n }
            return Array(bytes[at..<at + n])
        }
        mutating func skip(_ n: Int) throws { _ = try take(n) }
        mutating func tag() throws -> String { String(decoding: try take(4), as: UTF8.self) }
        mutating func vlq() throws -> Int {
            var v = 0
            for _ in 0..<4 {
                let b = try u8()
                v = v << 7 | Int(b & 0x7F)
                if b & 0x80 == 0 { return v }
            }
            throw MidiFileError.truncated
        }
    }
}
