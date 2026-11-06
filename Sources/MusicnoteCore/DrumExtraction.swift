import Accelerate
import AVFoundation
import Foundation

// MARK: - Onsets

/// One detected hit in a separated kit-piece track.
public struct DrumOnset: Hashable, Sendable {
    public var time: Double      // seconds from the start of the analysed audio
    public var level: Double     // peak level (dBFS) in the first 40 ms
    public var decay: Double     // seconds until 20 dB below the peak (capped by the next hit)
    public var pitch: Double?    // strongest partial 40–600 Hz, toms only

    public init(time: Double, level: Double, decay: Double, pitch: Double? = nil) {
        self.time = time; self.level = level; self.decay = decay; self.pitch = pitch
    }
}

/// Spectral-flux onset detection tuned for isolated kit pieces: each track already holds a
/// single instrument, so a hit is a jump in log spectrum that stands well above its
/// neighbourhood and is loud enough relative to the track's main hits (separation bleed
/// sits 30 dB or more below).
public enum DrumOnsetDetector {
    static let n = 1024, hop = 128, block = 44

    public static func detect(_ x: [Float], sampleRate sr: Double = 44100, pitched: Bool = false) -> [DrumOnset] {
        guard x.count > n * 2 else { return [] }
        let peakAbs = x.reduce(Float(0)) { max($0, abs($1)) }
        guard peakAbs > 1e-5 else { return [] }

        // Envelope in 1 ms blocks: peak level with a 10 ms release, so a low drum's cycles
        // don't read as separate rises.
        let blocks = x.count / block
        var env = [Float](repeating: 0, count: blocks)
        let release = Float(exp(-1.0 / 10))
        x.withUnsafeBufferPointer { xp in
            for b in 0..<blocks {
                var m: Float = 0
                vDSP_maxmgv(xp.baseAddress! + b * block, 1, &m, vDSP_Length(block))
                env[b] = max(m, b > 0 ? env[b - 1] * release : 0)
            }
        }

        // Log-magnitude spectral flux, on the signal scaled to its own peak.
        let frames = (x.count - n) / hop + 1
        let log2n = vDSP_Length(10)
        let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(fft) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var prev = [Float](repeating: 0, count: n / 2), cur = prev
        var flux = [Float](repeating: 0, count: frames)
        var re = [Float](repeating: 0, count: n / 2), im = re, buf = [Float](repeating: 0, count: n)
        let scale = 1 / peakAbs
        for t in 0..<frames {
            for i in 0..<n { buf[i] = x[t * hop + i] * window[i] * scale }
            re.withUnsafeMutableBufferPointer { rb in im.withUnsafeMutableBufferPointer { ib in
                var z = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                buf.withUnsafeBufferPointer { b in b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &z, 1, vDSP_Length(n / 2)) } }
                vDSP_fft_zrip(fft, &z, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&z, 1, &cur, 1, vDSP_Length(n / 2))
            } }
            var f: Float = 0
            for k in 1..<(n / 2) {
                let l = log1p(100 * cur[k])
                let d = l - prev[k]
                if d > 0 { f += d }
                prev[k] = l
            }
            flux[t] = t == 0 ? 0 : f
        }
        let fmax = flux.max() ?? 0
        guard fmax > 0 else { return [] }

        // Peaks: local maximum, above the local mean by a margin, at least 35 ms apart.
        let minGap = Int(0.035 * sr) / hop
        var picks: [Int] = []
        for t in 2..<max(2, frames - 2) {
            let v = flux[t]
            guard v >= 0.06 * fmax else { continue }
            let lo = max(0, t - 3), hi = min(frames - 1, t + 3)
            guard (lo...hi).allSatisfy({ flux[$0] <= v }) else { continue }
            let mlo = max(0, t - 16), mhi = min(frames - 1, t + 4)
            let mean = flux[mlo...mhi].reduce(0, +) / Float(mhi - mlo + 1)
            guard v >= mean + 0.05 * fmax else { continue }
            if let last = picks.last, t - last < minGap {
                if v > flux[last] { picks[picks.count - 1] = t }
                continue
            }
            picks.append(t)
        }

        // Onset time: first 1 ms block reaching 30 % of the peak that follows within 40 ms.
        let blocksPerSec = sr / Double(block)
        var raw: [(block: Int, peak: Float)] = []
        for t in picks {
            let center = (t * hop + n / 2) / block
            let from = max(0, center - n / block), to = min(blocks - 1, center + Int(0.04 * blocksPerSec))
            guard from < to else { continue }
            var pk: Float = 0, pkAt = from
            for b in from...to where env[b] > pk { pk = env[b]; pkAt = b }
            var on = pkAt
            while on > from, env[on - 1] >= 0.3 * pk { on -= 1 }
            // A new hit must rise 6 dB above what was already sounding just before it; the
            // body of the previous hit or a ringing cymbal re-peaking is not an attack.
            let pre = env[max(0, on - 8)..<max(1, on)].max() ?? 0
            if pk < 2 * pre { continue }
            if let last = raw.last, on - last.block < Int(0.035 * blocksPerSec) {
                if pk > last.peak { raw[raw.count - 1] = (on, pk) }
                continue
            }
            raw.append((on, pk))
        }
        guard !raw.isEmpty else { return [] }

        // Level gate against bleed: within 30 dB of the track's strong hits and above −60 dBFS.
        let levels = raw.map { 20 * log10(Double(max($0.peak, 1e-9))) }
        let ref = levels.sorted()[Int(Double(levels.count - 1) * 0.9)]
        var out: [DrumOnset] = []
        for (i, r) in raw.enumerated() where levels[i] >= max(ref - 30, -60) {
            let nextBlock = i + 1 < raw.count ? raw[i + 1].block : blocks
            var d = r.block
            let floor = r.peak * 0.1
            while d < min(blocks - 1, nextBlock, r.block + Int(1.5 * blocksPerSec)), env[d] > floor || d < r.block + 3 { d += 1 }
            let time = Double(r.block * block) / sr
            out.append(DrumOnset(time: time, level: levels[i], decay: Double(d - r.block) / blocksPerSec,
                                 pitch: pitched ? strongestPartial(x, at: r.block * block, sampleRate: sr) : nil))
        }
        return out
    }

    /// Strongest spectral peak between 40 and 600 Hz in the 186 ms after `start`.
    static func strongestPartial(_ x: [Float], at start: Int, sampleRate sr: Double) -> Double? {
        let m = 8192, log2m = vDSP_Length(13)
        guard start < x.count else { return nil }
        var buf = [Float](repeating: 0, count: m)
        var w = [Float](repeating: 0, count: m)
        vDSP_hann_window(&w, vDSP_Length(m), Int32(vDSP_HANN_NORM))
        for i in 0..<min(m, x.count - start) { buf[i] = x[start + i] * w[i] }
        let fft = vDSP_create_fftsetup(log2m, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(fft) }
        var re = [Float](repeating: 0, count: m / 2), im = re, mag = re
        re.withUnsafeMutableBufferPointer { rb in im.withUnsafeMutableBufferPointer { ib in
            var z = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
            buf.withUnsafeBufferPointer { b in b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: m / 2) { vDSP_ctoz($0, 2, &z, 1, vDSP_Length(m / 2)) } }
            vDSP_fft_zrip(fft, &z, 1, log2m, FFTDirection(FFT_FORWARD))
            vDSP_zvabs(&z, 1, &mag, 1, vDSP_Length(m / 2))
        } }
        let hz = sr / Double(m)
        let lo = Int(40 / hz), hi = Int(600 / hz)
        guard let k = (lo...hi).max(by: { mag[$0] < mag[$1] }), mag[k] > 0 else { return nil }
        return Double(k) * hz
    }
}

// MARK: - Onsets → groove

public enum DrumTranscriber {
    public struct Result: Sendable {
        public var groove: DrumGroove
        /// Clip time (µs) of the groove's first step.
        public var startUs: Int64
        public var notes: [String]
    }

    struct Placed { var lane: Int; var q: Double; var velocity: Int }

    /// Builds a groove on the clip's confirmed grid. `onsets` times are clip seconds (may
    /// be negative inside the lead-in). The groove starts at the bar line on or before the
    /// clip start and covers the clip, less empty bars at either end.
    public static func groove(onsets: [DrumPiece: [DrumOnset]], grid: BeatGrid, durationUs: Int64) -> Result {
        let perBar = grid.meter.quarterBeatsPerBar
        let anchorQ = grid.barAnchorQ
        let startQ = anchorQ + perBar * floor((grid.q(atUs: 0) - anchorQ) / perBar + 1e-6)
        let bars = max(1, min(64, Int(ceil((grid.q(atUs: durationUs) - startQ) / perBar - 1e-6))))
        let endQ = startQ + Double(bars) * perBar
        let beatSec = grid.beatUs / 1e6

        // Lanes and their hits.
        var lanes: [DrumLane] = []
        var placed: [Placed] = []
        func lane(_ name: String, _ note: Int, _ piece: DrumPiece) -> Int {
            if let i = lanes.firstIndex(where: { $0.note == note }) { return i }
            lanes.append(DrumLane(name: name, note: note, piece: piece))
            return lanes.count - 1
        }
        func velocities(_ hits: [DrumOnset]) -> [Int] {
            guard !hits.isEmpty else { return [] }
            let ref = hits.map(\.level).sorted()[Int(Double(hits.count - 1) * 0.9)]
            return hits.map { max(15, min(127, Int((110 + ($0.level - ref) * 3).rounded()))) }
        }
        func q(_ t: Double) -> Double { grid.q(atUs: Int64(t * 1e6)) - startQ }
        func inRange(_ h: DrumOnset) -> Bool { let x = q(h.time); return x >= -0.02 && x < endQ - startQ - 0.02 }

        let cleaned = withoutCymbalLeaks(onsets)
        for piece in DrumPiece.allCases {
            let hits = (cleaned[piece] ?? []).filter(inRange)
            let vel = velocities(hits)
            for (i, h) in hits.enumerated() {
                let li: Int
                switch piece {
                case .kick: li = lane("底鼓", 36, .kick)
                case .snare: li = lane("军鼓", 38, .snare)
                case .hihat:
                    let next = i + 1 < hits.count ? hits[i + 1].time - h.time : .infinity
                    li = h.decay >= 0.18 && next >= 0.16 ? lane("开镲", 46, .hihat) : lane("闭镲", 42, .hihat)
                case .toms: li = tomLane(h, hits, lane)
                case .cymbals:
                    // Time-keeping cymbal hits come in runs a beat or less apart: ride; the rest crash.
                    let gap = { (j: Int) in j >= 0 && j < hits.count ? abs(hits[j].time - h.time) : .infinity }
                    let inRun = (gap(i - 1) <= beatSec * 1.05 && (gap(i + 1) <= beatSec * 1.05 || gap(i - 2) <= beatSec * 2.1))
                        || (gap(i + 1) <= beatSec * 1.05 && gap(i + 2) <= beatSec * 2.1)
                    li = inRun ? lane("叮叮镲", 51, .cymbals) : lane("吊镲", 49, .cymbals)
                case .other: li = lane("打击乐", 63, .other)
                }
                placed.append(Placed(lane: li, q: max(0, q(h.time)), velocity: vel[i]))
            }
        }
        for (name, note, piece) in [("底鼓", 36, DrumPiece.kick), ("军鼓", 38, .snare), ("闭镲", 42, .hihat)] { _ = lane(name, note, piece) }
        let order = [36, 38, 39, 42, 46, 50, 48, 47, 45, 43, 41, 51, 49, 63]
        let sortedIdx = lanes.indices.sorted { (order.firstIndex(of: lanes[$0].note) ?? 99) < (order.firstIndex(of: lanes[$1].note) ?? 99) }
        let remap = Dictionary(uniqueKeysWithValues: sortedIdx.enumerated().map { ($0.element, $0.offset) })
        lanes = sortedIdx.map { lanes[$0] }
        placed = placed.map { var p = $0; p.lane = remap[p.lane]!; return p }

        // Grid: sixteenths (with the best swing), unless triplets or 32nds fit clearly better.
        var notes: [String] = []
        let qs = placed.map(\.q)
        let swing = bestSwing(qs)
        var steps = 4, sw = swing
        if fit(qs, steps: 4, swing: swing) < 0.85 {
            // Coarsest grid most hits sit on; else the one that holds the most.
            let fits = [3, 6, 8].map { (steps: $0, fit: fit(qs, steps: $0)) }
            let best = fits.first { $0.fit >= 0.85 } ?? fits.max { $0.fit < $1.fit }!
            if best.fit > fit(qs, steps: 4, swing: swing) + 0.1 { steps = best.steps; sw = 50 }
        }
        var g = DrumGroove(meter: grid.meter, stepsPerBeat: steps, bars: bars, swing: sw, feel: 1, lanes: lanes)

        // Place: nearest step after swing; the rest is the step's nudge. Several hits in one
        // step become a ratchet when evenly spaced, else the loudest wins.
        var cells: [Int: [Int: [Placed]]] = [:]
        for p in placed {
            let exact = p.q * Double(steps)
            let base = Int(exact.rounded())
            let idx = (base - 1...base + 1).filter { $0 >= 0 && $0 < g.totalSteps }
                .min { abs(DrumOps.stepQ(g, index: $0) - p.q) < abs(DrumOps.stepQ(g, index: $1) - p.q) } ?? 0
            cells[p.lane, default: [:]][idx, default: []].append(p)
        }
        let stepLen = 1 / Double(steps)
        var timingErr: [Double] = []
        for (li, byStep) in cells {
            for (idx, ps) in byStep {
                let first = ps.min { $0.q < $1.q }!
                let nudge = max(-0.5, min(0.5, (first.q - DrumOps.stepQ(g, index: idx)) / stepLen))
                timingErr.append(abs(nudge) * stepLen * beatSec)
                var s = DrumStep(index: idx, velocity: ps.map(\.velocity).max()!, nudge: (nudge * 100).rounded() / 100)
                if ps.count > 1 {
                    let span = (ps.map(\.q).max()! - first.q) / stepLen
                    if ps.count <= 4, span > 0.25 { s.repeats = ps.count }
                }
                g.lanes[li].steps.append(s)
            }
            g.lanes[li].steps.sort { $0.index < $1.index }
        }

        // Leading and trailing empty bars (a clip starting just before a bar line) go.
        var firstQ = startQ
        let used = g.lanes.flatMap { $0.steps.map(\.index) }
        if let lo = used.min(), let hi = used.max() {
            let first = lo / g.stepsPerBar, last = hi / g.stepsPerBar
            if first > 0 || last < g.bars - 1 {
                DrumOps.crop(&g, bars: first..<(last + 1))
                firstQ += Double(first) * perBar
            }
        }

        let gridName = DrumGroove.resolutions.first { $0.steps == steps }?.name ?? "\(steps)"
        notes.append("格子：\(gridName)" + (sw > 50 ? "，摇摆 \(Int(sw.rounded()))%" : ""))
        if !timingErr.isEmpty {
            let mean = timingErr.reduce(0, +) / Double(timingErr.count) * 1000
            notes.append(String(format: "离格子平均 %.0f 毫秒（保存在每步的微移里）", mean))
        }
        for l in g.lanes where !l.steps.isEmpty { notes.append("\(l.name) \(l.steps.count) 下") }
        return Result(groove: g, startUs: grid.us(atQ: firstQ), notes: notes)
    }

    /// The cymbal track picks up hi-hat strokes while a crash rings. A cymbal onset is
    /// dropped when it lines up with a hi-hat hit (±25 ms) and is 6 dB under the track's
    /// loudest, or when it is 20 dB under (real cymbal strokes are seldom that soft).
    static func withoutCymbalLeaks(_ onsets: [DrumPiece: [DrumOnset]]) -> [DrumPiece: [DrumOnset]] {
        guard let cym = onsets[.cymbals], let top = cym.map(\.level).max() else { return onsets }
        let hats = onsets[.hihat] ?? []
        var out = onsets
        out[.cymbals] = cym.filter { c in
            if c.level < top - 20 { return false }
            let onHat = hats.contains { abs($0.time - c.time) <= 0.025 }
            return !(onHat && c.level <= top - 6)
        }
        return out
    }

    /// Toms by pitch: up to four drums, split at the widest gaps (≥ 15 % apart).
    static func tomLane(_ h: DrumOnset, _ hits: [DrumOnset], _ lane: (String, Int, DrumPiece) -> Int) -> Int {
        let pitches = Array(Set(hits.compactMap(\.pitch))).sorted()
        guard let p = h.pitch, pitches.count > 1 else { return lane("中嗵", 47, .toms) }
        var gaps: [(ratio: Double, at: Double)] = []
        for i in 1..<pitches.count { gaps.append((pitches[i] / pitches[i - 1], pitches[i - 1])) }
        let cuts = gaps.filter { $0.ratio >= 1.15 }.sorted { $0.ratio > $1.ratio }.prefix(3).map(\.at).sorted()
        let group = cuts.filter { p > $0 }.count // 0 = lowest
        let kits: [[(String, Int)]] = [[("中嗵", 47)], [("落地嗵", 43), ("高嗵", 50)],
                                       [("落地嗵", 43), ("中嗵", 47), ("高嗵", 50)],
                                       [("落地嗵", 43), ("低嗵", 45), ("中嗵", 47), ("高嗵", 50)]]
        let t = kits[cuts.count][group]
        return lane(t.0, t.1, .toms)
    }

    /// Mean distance (quarters) from each hit to its nearest step on a grid of `steps` per beat.
    static func cost(_ qs: [Double], steps: Int, swing: Double = 50) -> Double {
        guard !qs.isEmpty else { return 0 }
        let g = DrumGroove(stepsPerBeat: steps, bars: 64, swing: swing, lanes: [])
        return qs.map { q in
            let base = Int((q * Double(steps)).rounded())
            return (base - 1...base + 1).map { abs(DrumOps.stepQ(g, index: $0) - q) }.min()!
        }.reduce(0, +) / Double(qs.count)
    }

    /// Share of hits within a fifth of a step of the grid.
    static func fit(_ qs: [Double], steps: Int, swing: Double = 50) -> Double {
        guard !qs.isEmpty else { return 1 }
        let g = DrumGroove(stepsPerBeat: steps, bars: 64, swing: swing, lanes: [])
        let tol = 0.2 / Double(steps)
        return Double(qs.filter { q in
            let base = Int((q * Double(steps)).rounded())
            return (base - 1...base + 1).contains { abs(DrumOps.stepQ(g, index: $0) - q) <= tol }
        }.count) / Double(qs.count)
    }

    /// Swing (50…75) that fits sixteenths best; straight unless swing clearly helps and
    /// enough hits sit on the swung (odd) sixteenths.
    static func bestSwing(_ qs: [Double]) -> Double {
        let straight = cost(qs, steps: 4)
        var best = (swing: 50.0, cost: straight)
        for s in stride(from: 52.0, through: 75, by: 1) {
            let c = cost(qs, steps: 4, swing: s)
            if c < best.cost { best = (s, c) }
        }
        let g = DrumGroove(stepsPerBeat: 4, bars: 64, swing: best.swing, lanes: [])
        let odd = qs.filter { q in abs(q - DrumOps.stepQ(g, index: Int(floor(q * 2)) * 2 + 1)) < 0.05 }.count
        return best.cost < 0.75 * straight && odd >= 4 ? best.swing : 50
    }
}

// MARK: - Pipeline stage

extension Pipeline {
    /// Clip → six stems → drum stem → kit pieces → groove on the clip's grid. The kit-piece
    /// audio is kept (FLAC, trimmed so frame 0 is the groove's first step) for comparison.
    public func extractDrums(_ item: AnalysisItem, grid: BeatGrid, songTitle: String, patternId: UUID,
                             jobDir: URL, progress: @escaping ProgressHandler) async throws -> (DrumPattern, [String]) {
        guard item.hasValidTiming, let timing = item.timing else {
            throw WorkerError(code: "TEMPO_KEY_UNCONFIRMED", message: "需要先确认速度网格", retryable: false)
        }
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let leadIn = Self.leadIn(item)
        let clip = jobDir.appendingPathComponent("clip.wav")
        progress(StageProgress("裁剪选区"))
        var wider = item
        wider.trimStartUs -= leadIn
        try await extractClip(wider, to: clip)

        let stems = jobDir.appendingPathComponent("stems"), kit = jobDir.appendingPathComponent("kit")
        for d in [stems, kit] { paths.removeOwned(d) }
        nonisolated(unsafe) var logicVersion: String?
        for (label, args) in [("拆出鼓轨", ["--input", clip.path, "--output-dir", stems.path]),
                              ("拆成单个鼓件", ["--drums", "--input", stems.appendingPathComponent("drums.wav").path, "--output-dir", kit.path])] {
            progress(StageProgress(label, 0, nil))
            nonisolated(unsafe) var failure: WorkerError?
            let w = WorkerProcess(tools.separatorBinary, args)
            let r = try await w.run { line in
                guard let o = decodeJSONLine(line), let ev = o["event"] as? String else { return }
                switch ev {
                case "started": logicVersion = o["logicVersion"] as? String ?? logicVersion
                case "progress": progress(StageProgress(label, o["completed"] as? Int ?? 0, o["total"] as? Int))
                case "error": failure = WorkerError(code: o["code"] as? String ?? "SEPARATION_FAILED", message: o["message"] as? String ?? "拆轨失败")
                default: break
                }
            }
            try Task.checkCancellation()
            if let failure { throw failure }
            guard r.status == 0 else { throw WorkerError(code: "SEPARATION_FAILED", message: "\(label)失败：\(r.stderr.suffix(300))") }
        }
        let drumLevel = try Self.rmsDb(stems.appendingPathComponent("drums.wav"))
        guard drumLevel > -50 else {
            throw WorkerError(code: "NO_DRUMS", message: String(format: "这个片段几乎没有鼓（鼓轨电平 %.0f dB）", drumLevel), retryable: false)
        }

        progress(StageProgress("找出每一下"))
        let leadSec = Double(leadIn) / 1e6
        var onsets: [DrumPiece: [DrumOnset]] = [:]
        for piece in DrumPiece.allCases {
            let x = try Self.mono(kit.appendingPathComponent("\(piece.rawValue).wav"))
            onsets[piece] = DrumOnsetDetector.detect(x, pitched: piece == .toms).map { var o = $0; o.time -= leadSec; return o }
        }
        let result = DrumTranscriber.groove(onsets: onsets, grid: grid, durationUs: item.durationUs)

        // Publish audio, frame 0 = the groove's first step, as long as the groove.
        progress(StageProgress("保存原声"))
        let dest = paths.analysisAssets(item.id).appendingPathComponent("drums-\(patternId.uuidString.prefix(8))", isDirectory: true)
        paths.removeOwned(dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let offsetFrames = Int64((Double(result.startUs + leadIn) * 44_100 / 1_000_000).rounded())
        let lengthFrames = Int64((result.groove.lengthQ * grid.beatUs / 1e6 * 44_100).rounded())
        let filter = offsetFrames >= 0
            ? "atrim=start_sample=\(offsetFrames):end_sample=\(offsetFrames + lengthFrames),asetpts=PTS-STARTPTS"
            : "adelay=\(-offsetFrames)S:all=1,atrim=end_sample=\(lengthFrames)"
        var audio: [String: String] = [:]
        let sources = [("mix", clip), ("drums", stems.appendingPathComponent("drums.wav"))]
            + DrumPiece.allCases.map { ($0.rawValue, kit.appendingPathComponent("\($0.rawValue).wav")) }
        for (name, src) in sources {
            let out = dest.appendingPathComponent("\(name).flac")
            let w = WorkerProcess(tools.ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", src.path, "-af", filter, "-c:a", "flac", out.path])
            let r = try await w.run()
            guard r.status == 0 else { throw WorkerError(code: "ENCODE_FAILED", message: "保存\(name)失败：\(r.stderr.suffix(200))") }
            audio[name] = paths.relative(out)
        }
        for d in [stems, kit] { paths.removeOwned(d) }

        let source = DrumSource(analysisId: item.id, songTitle: songTitle, clipTitle: item.title, bpm: timing.bpm,
                                trimRevision: item.trimRevision, timingRevision: item.timingRevision, startUs: result.startUs,
                                audio: audio, logicVersion: logicVersion)
        let p = DrumPattern(id: patternId, title: "\(songTitle) · \(item.title)", bpm: timing.bpm, groove: result.groove, source: source)
        return (p, result.notes)
    }

    /// The clip's grid with a bar line: the confirmed one, else the one harmony grouping used,
    /// else estimated from the confirmed MIDI (as the analysis agent does).
    public func drumGrid(_ item: AnalysisItem) -> BeatGrid? {
        guard item.hasValidTiming, var g = item.timing?.grid.anchoredOnBeat else { return nil }
        if g.barAnchorUs == nil {
            let harmony = store.all(HarmonyRevision.self, owner: item.id).max { $0.revision < $1.revision }
            let midi = item.confirmedMidiRevision.flatMap { r in store.all(MidiRevision.self, owner: item.id).first { $0.revision == r } }
            g.barAnchorUs = harmony?.barAnchorUs ?? ChordGrouper().estimatedBarAnchor(notes: midi?.notes ?? [], grid: g)
        }
        return g
    }

    /// A file's channels averaged to one, at its own rate.
    public static func monoSamples(_ url: URL) throws -> [Float] { try mono(url) }

    static func mono(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(max(1, f.length))) else { return [] }
        try f.read(into: b)
        let n = Int(b.frameLength), ch = Int(b.format.channelCount)
        guard n > 0, let d = b.floatChannelData else { return [] }
        var out = [Float](repeating: 0, count: n)
        for c in 0..<ch { vDSP_vadd(out, 1, d[c], 1, &out, 1, vDSP_Length(n)) }
        var k = 1 / Float(ch)
        vDSP_vsmul(out, 1, &k, &out, 1, vDSP_Length(n))
        return out
    }

    static func rmsDb(_ url: URL) throws -> Double {
        let x = try mono(url)
        guard !x.isEmpty else { return -200 }
        var ms: Float = 0
        vDSP_measqv(x, 1, &ms, vDSP_Length(x.count))
        return 10 * log10(Double(max(ms, 1e-20)))
    }
}
