// Drum kit-piece separation with Logic Pro 13's DrumSplitter model.
//
// Input is a separated drum stem (44.1 kHz stereo); output is six float WAVs in --output-dir:
// kick, snare, hihat, toms, cymbals, other. Same JSON-lines protocol as the six-stem split.
//
// The model (checkpoint_277000_zeb99ngfer) is a band-split mask network with a time-domain
// branch: each source is time_output + iSTFT(stft_real, stft_imag). The STFT is the model's
// own (2048-point periodic Hann, hop 1024, centred), checked from its kernels; the six
// outputs sum back to the input within about −44 dB on a GM test kit.
//
// Output order checked on 13.0 by rendering one GM kit piece per window and seeing which
// output carries it (Logic's menu lists them in a different order):
//   0 kick · 1 snare (and claps) · 2 hi-hat (open, closed, pedal, shakers, tambourine)
//   3 toms · 4 cymbals (crash, ride, ride bell) · 5 other (cowbell, congas, wood block)
import Accelerate
import AVFoundation
import CoreML
import Foundation

let drumModelPath = logicApp + "/Contents/Frameworks/MAMLStemSplitter.framework/Versions/A/Resources/checkpoint_277000_zeb99ngfer.mlmodelc"
let drumNames = ["kick", "snare", "hihat", "toms", "cymbals", "other"]

func separateDrums() throws {
    guard let inputPath = option("--input"), let outputDir = option("--output-dir") else {
        throw HelperError(code: "INVALID_ARGUMENTS", message: "usage: musicnote-separate --drums --input DRUMS.wav --output-dir DIR")
    }
    guard FileManager.default.fileExists(atPath: drumModelPath) else {
        throw HelperError(code: "MODEL_UNAVAILABLE", message: "需要 Logic Pro 13 的鼓细分模型（没有找到 \(drumModelPath)）")
    }
    let N = 266240, nfft = 2048, hop = 1024, frames = 261
    let overlap = 40960, step = N - overlap
    let source = try AVAudioFile(forReading: URL(fileURLWithPath: inputPath))
    guard source.processingFormat.sampleRate == 44100, source.processingFormat.channelCount == 2 else {
        throw HelperError(code: "INVALID_INPUT", message: "drum stem must be 44.1 kHz stereo")
    }
    guard let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(max(source.length, 1))) else {
        throw HelperError(code: "INVALID_INPUT", message: "cannot allocate input buffer")
    }
    try source.read(into: input)
    let count = Int(input.frameLength)
    guard count > 0 else { throw HelperError(code: "INVALID_RANGE", message: "empty drum stem") }
    let chunks = count <= N ? 1 : 1 + (count - N + step - 1) / step
    var started: [String: Any] = ["event": "started", "frames": count, "chunks": chunks, "model": "drums"]
    if let v = logicVersion() { started["logicVersion"] = v }
    emit(started)

    let startTime = Date()
    let config = MLModelConfiguration()
    config.computeUnits = .cpuAndGPU
    let model: MLModel
    do { model = try MLModel(contentsOf: URL(fileURLWithPath: drumModelPath), configuration: config) }
    catch { throw HelperError(code: "MODEL_UNAVAILABLE", message: "cannot load drum model: \(error.localizedDescription)") }
    let outs = model.modelDescription.outputDescriptionsByName
    guard outs["time_output"] != nil, outs["stft_real"] != nil, outs["stft_imag"] != nil else {
        throw HelperError(code: "MODEL_UNAVAILABLE", message: "unexpected drum model outputs; Logic version may have changed")
    }

    let fft = vDSP_create_fftsetup(vDSP_Length(11), FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(fft) }
    let window = (0..<nfft).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nfft))) }
    var denom = [Float](repeating: 0, count: N + nfft)
    for t in 0..<frames { for i in 0..<nfft { denom[t * hop + i] += window[i] * window[i] } }

    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
    try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    var files: [AVAudioFile] = []
    for name in drumNames {
        let path = outputDir + "/" + name + ".wav"
        if FileManager.default.fileExists(atPath: path) {
            throw HelperError(code: "INVALID_ARGUMENTS", message: "refusing to overwrite \(path)")
        }
        files.append(try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false))
    }
    var carry = [[Float]](repeating: [Float](repeating: 0, count: overlap), count: 12)
    emit(["event": "progress", "completed": 0, "total": chunks])
    for chunk in 0..<chunks {
        try autoreleasepool {
            let offset = chunk * step
            let valid = min(N, count - offset)
            let a = try MLMultiArray(shape: [1, 2, NSNumber(value: N)], dataType: .float32)
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            p.initialize(repeating: 0, count: 2 * N)
            for c in 0..<2 { p.advanced(by: c * N).update(from: input.floatChannelData![c].advanced(by: offset), count: valid) }
            let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": a]))
            guard let time = prediction.featureValue(for: "time_output")?.multiArrayValue,
                  let real = prediction.featureValue(for: "stft_real")?.multiArrayValue,
                  let imag = prediction.featureValue(for: "stft_imag")?.multiArrayValue,
                  time.dataType == .float32, real.dataType == .float32, imag.dataType == .float32 else {
                throw HelperError(code: "SEPARATION_FAILED", message: "drum model returned unexpected arrays")
            }
            let tp = time.dataPointer.assumingMemoryBound(to: Float.self), ts = time.strides.map(\.intValue)
            let rp = real.dataPointer.assumingMemoryBound(to: Float.self), rs = real.strides.map(\.intValue)
            let ip = imag.dataPointer.assumingMemoryBound(to: Float.self), iss = imag.strides.map(\.intValue)
            var decoded = [[Float]]()
            var re = [Float](repeating: 0, count: 1024), im = re, frame = [Float](repeating: 0, count: nfft)
            for ch in 0..<12 {
                let s = ch / 2, c = ch % 2
                // iSTFT of the masked spectrum (centred: drop nfft/2 at the start).
                var signal = [Float](repeating: 0, count: N + nfft)
                for t in 0..<frames {
                    let ro = ch * rs[1] + t * rs[3], io = ch * iss[1] + t * iss[3]
                    for k in 0..<1024 { re[k] = rp[ro + k * rs[2]]; im[k] = ip[io + k * iss[2]] }
                    im[0] = rp[ro + 1024 * rs[2]] // zrip packs the Nyquist real part into imag[0]
                    re.withUnsafeMutableBufferPointer { rb in im.withUnsafeMutableBufferPointer { ib in
                        var z = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                        vDSP_fft_zrip(fft, &z, 1, 11, FFTDirection(FFT_INVERSE))
                        frame.withUnsafeMutableBufferPointer { fb in
                            fb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: 1024) { vDSP_ztoc(&z, 1, $0, 2, 1024) }
                        }
                    } }
                    for i in 0..<nfft { signal[t * hop + i] += frame[i] / Float(nfft) * window[i] }
                }
                let to = s * ts[1] + c * ts[2]
                var audio = [Float](repeating: 0, count: valid)
                for i in 0..<valid {
                    let d = denom[i + nfft / 2]
                    let x = (d > 1e-8 ? signal[i + nfft / 2] / d : 0) + tp[to + i * ts[3]]
                    guard x.isFinite else { throw HelperError(code: "SEPARATION_FAILED", message: "nonfinite drum model output") }
                    audio[i] = x
                }
                if chunk > 0 { for i in 0..<min(overlap, valid) { let w = Float(i) / Float(overlap); audio[i] = carry[ch][i] * (1 - w) + audio[i] * w } }
                if valid > step { for i in 0..<(valid - step) { carry[ch][i] = audio[step + i] } }
                decoded.append(audio)
            }
            let writeCount = chunk == chunks - 1 ? valid : min(step, valid)
            for s in 0..<6 {
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(writeCount))!
                b.frameLength = AVAudioFrameCount(writeCount)
                for c in 0..<2 { decoded[2 * s + c].withUnsafeBufferPointer { b.floatChannelData![c].update(from: $0.baseAddress!, count: writeCount) } }
                try files[s].write(from: b)
            }
            emit(["event": "progress", "completed": chunk + 1, "total": chunks])
        }
    }
    files.removeAll()
    emit(["event": "done", "frames": count, "seconds": Date().timeIntervalSince(startTime)])
}
