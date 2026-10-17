import Foundation

/// Standard MIDI File (Type 1) writer. Track 0 carries tempo, meter, key and
/// section markers; track 1 carries the notes.
public struct MidiFileWriter {
    public struct Note: Hashable {
        public var pitch: Int
        public var velocity: Int
        public var startTick: Int
        public var durationTicks: Int
        public init(pitch: Int, velocity: Int, startTick: Int, durationTicks: Int) {
            self.pitch = pitch; self.velocity = velocity; self.startTick = startTick; self.durationTicks = durationTicks
        }
    }

    public var ppq = MidiTicks.ppq
    public var bpm: Double
    public var meter: Meter
    public var key: KeySignature?
    public var markers: [(tick: Int, text: String)] = []
    public var trackName = "Musicnote"
    public var program: Int? = nil

    public init(bpm: Double, meter: Meter, key: KeySignature?) { self.bpm = bpm; self.meter = meter; self.key = key }

    public func data(notes: [Note]) -> Data {
        var file = Data("MThd".utf8)
        file.append(be32(6)); file.append(be16(1)); file.append(be16(2)); file.append(be16(ppq))

        // Conductor track
        var meta: [(Int, [UInt8])] = []
        meta.append((0, [0xFF, 0x03] + vlqBytes(trackName.utf8.count) + Array(trackName.utf8)))
        let mpq = Tempo.microsecondsPerQuarter(bpm)
        meta.append((0, [0xFF, 0x51, 0x03, UInt8((mpq >> 16) & 0xFF), UInt8((mpq >> 8) & 0xFF), UInt8(mpq & 0xFF)]))
        let dd = UInt8(max(0, Int(log2(Double(meter.denominator)))))
        meta.append((0, [0xFF, 0x58, 0x04, UInt8(meter.numerator), dd, 24, 8]))
        if let key, let sf = Self.sharpsFlats(key) {
            meta.append((0, [0xFF, 0x59, 0x02, UInt8(bitPattern: Int8(sf)), key.mode == .minor ? 1 : 0]))
        }
        for m in markers {
            let bytes = Array(m.text.utf8)
            meta.append((m.tick, [0xFF, 0x06] + vlqBytes(bytes.count) + bytes))
        }
        file.append(track(meta))

        // Note track
        var events: [(Int, [UInt8])] = []
        if let program { events.append((0, [0xC0, UInt8(program & 0x7F)])) }
        for n in notes where n.durationTicks > 0 && (0...127).contains(n.pitch) {
            let v = UInt8(min(127, max(1, n.velocity)))
            events.append((n.startTick, [0x90, UInt8(n.pitch), v]))
            events.append((n.startTick + n.durationTicks, [0x80, UInt8(n.pitch), 0]))
        }
        // Note-offs before note-ons at the same tick so repeated notes retrigger cleanly.
        events.sort { a, b in a.0 != b.0 ? a.0 < b.0 : (a.1[0] & 0xF0) == 0x80 && (b.1[0] & 0xF0) == 0x90 }
        file.append(track(events))
        return file
    }

    /// Key-signature sharps (+) / flats (−) for the MIDI meta event.
    static func sharpsFlats(_ key: KeySignature) -> Int? {
        let majorTonic = key.mode == .major ? key.tonic : Pitch.pc(key.tonic + 3)
        let flats = Pitch.prefersFlats(key)
        let sharpTable = [0: 0, 7: 1, 2: 2, 9: 3, 4: 4, 11: 5, 6: 6, 1: 7]
        let flatTable = [0: 0, 5: -1, 10: -2, 3: -3, 8: -4, 1: -5, 6: -6, 11: -7]
        return flats ? (flatTable[majorTonic] ?? sharpTable[majorTonic]) : (sharpTable[majorTonic] ?? flatTable[majorTonic])
    }

    private func track(_ events: [(Int, [UInt8])]) -> Data {
        var body = Data()
        var last = 0
        for (tick, bytes) in events.sorted(by: { $0.0 < $1.0 }) {
            body.append(contentsOf: vlqBytes(max(0, tick - last)))
            body.append(contentsOf: bytes)
            last = tick
        }
        body.append(contentsOf: [0x00, 0xFF, 0x2F, 0x00])
        var d = Data("MTrk".utf8)
        d.append(be32(body.count)); d.append(body)
        return d
    }

    private func vlqBytes(_ value: Int) -> [UInt8] {
        var v = value
        var bytes = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
        return bytes
    }

    private func be32(_ v: Int) -> Data { Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    private func be16(_ v: Int) -> Data { Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
}

/// Exports a confirmed clip MIDI take at its own confirmed tempo grid.
public enum ClipMidiExport {
    public static func data(notes: [MidiNote], timing: TimingConfirmation) -> Data {
        let grid = timing.grid
        // Shift so the earliest note (possibly a pickup before the origin) is at tick ≥ 0.
        let minQ = min(0, notes.map { grid.q(atUs: $0.startUs) }.min() ?? 0)
        let offsetBeats = minQ < 0 ? ceil(-minQ / grid.meter.quarterBeatsPerBar) * grid.meter.quarterBeatsPerBar : 0
        let out = notes.map { n -> MidiFileWriter.Note in
            let s = MidiTicks.ticks(q: grid.q(atUs: n.startUs) + offsetBeats)
            let e = MidiTicks.ticks(q: grid.q(atUs: n.endUs) + offsetBeats)
            return .init(pitch: n.pitch, velocity: n.velocity, startTick: s, durationTicks: max(1, e - s))
        }
        return MidiFileWriter(bpm: timing.bpm, meter: timing.meter, key: timing.key).data(notes: out)
    }
}
