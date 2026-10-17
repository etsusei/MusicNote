// Six-stem separation helper using the Logic Pro model installed on this Mac.
//
// Ported from work/separate.swift. Input is an already-trimmed 44.1 kHz stereo
// clip; output is six float WAVs in --output-dir (vocals, drums, bass, guitar,
// piano, other). MP3 encoding happens afterwards in workers/encode_stems.py.
//
// Protocol: JSON lines on stdout
//   {"event":"started","frames":N,"chunks":C,"gpu":"Apple M5","logicVersion":"12.3.1"}
//   {"event":"progress","completed":i,"total":C}
//   {"event":"done","frames":N,"seconds":S}
//   {"event":"error","code":"GPU_UNAVAILABLE","message":"..."}
import Accelerate
import AVFoundation
import CoreML
import Foundation
import Metal

let logicApp = "/Applications/Logic Pro.app"
let modelPath = logicApp + "/Contents/Resources/MAMachineLearningResources.bundle/Contents/Resources/ke77nsfms3_8024.mlmodelc"
// Model source order (verified from Logic's binary): bass, drums, other, vocals, guitar, piano.
let stemNames = ["bass", "drums", "other", "vocals", "guitar", "piano"]

struct HelperError: Error { let code: String; let message: String }

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func option(_ key: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func logicVersion() -> String? {
    let plist = URL(fileURLWithPath: logicApp + "/Contents/Info.plist")
    guard let dict = NSDictionary(contentsOf: plist) else { return nil }
    return dict["CFBundleShortVersionString"] as? String
}

func separate() throws {
    guard let inputPath = option("--input"), let outputDir = option("--output-dir") else {
        throw HelperError(code: "INVALID_ARGUMENTS", message: "usage: musicnote-separate --input CLIP.wav --output-dir DIR")
    }
    guard FileManager.default.fileExists(atPath: modelPath) else {
        throw HelperError(code: "MODEL_UNAVAILABLE", message: "Logic Pro stem model not found at \(modelPath)")
    }
    let N = 588800, hop = 512, fftN = 2048, frames = 1151, step = 529920
    let source = try AVAudioFile(forReading: URL(fileURLWithPath: inputPath))
    guard source.processingFormat.sampleRate == 44100, source.processingFormat.channelCount == 2 else {
        throw HelperError(code: "INVALID_INPUT", message: "clip must be 44.1 kHz stereo")
    }
    guard let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)) else {
        throw HelperError(code: "INVALID_INPUT", message: "cannot allocate input buffer")
    }
    try source.read(into: input)
    let count = Int(input.frameLength)
    guard count > 0 else { throw HelperError(code: "INVALID_RANGE", message: "empty clip") }
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw HelperError(code: "GPU_UNAVAILABLE", message: "Metal GPU unavailable")
    }
    let chunks = (count + step - 1) / step
    var started: [String: Any] = ["event": "started", "frames": count, "chunks": chunks, "gpu": device.name]
    if let v = logicVersion() { started["logicVersion"] = v }
    emit(started)

    let startTime = Date()
    let config = MLModelConfiguration()
    config.computeUnits = .cpuAndGPU
    let model: MLModel
    do { model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: config) }
    catch { throw HelperError(code: "MODEL_UNAVAILABLE", message: "cannot load model: \(error.localizedDescription)") }
    guard model.modelDescription.outputDescriptionsByName["var_11707"] != nil,
          model.modelDescription.outputDescriptionsByName["var_11751"] != nil else {
        throw HelperError(code: "MODEL_UNAVAILABLE", message: "unexpected model outputs; Logic version may have changed")
    }

    let fft = vDSP_create_fftsetup(vDSP_Length(11), FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(fft) }
    // Match MADSP synthesis: symmetric Hann; model analysis kernels use periodic Hann.
    let window = (0..<fftN).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftN - 1))) }
    var denom = [Float](repeating: 0, count: N + fftN)
    for t in 0..<frames { for i in 0..<fftN { denom[t * hop + i] += window[i] * window[i] } }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
    try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    var files: [AVAudioFile] = []
    for s in 0..<6 {
        let path = outputDir + "/" + stemNames[s] + ".wav"
        if FileManager.default.fileExists(atPath: path) {
            throw HelperError(code: "INVALID_ARGUMENTS", message: "refusing to overwrite \(path)")
        }
        files.append(try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false))
    }
    let overlap = N - step
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
            let features = try MLDictionaryFeatureProvider(dictionary: ["input": a])
            let prediction = try model.prediction(from: features)
            let real = prediction.featureValue(for: "var_11707")!.multiArrayValue!
            let imag = prediction.featureValue(for: "var_11751")!.multiArrayValue!
            let r = real.dataPointer.assumingMemoryBound(to: Float.self), im = imag.dataPointer.assumingMemoryBound(to: Float.self)
            let rs = real.strides.map { $0.intValue }, iss = imag.strides.map { $0.intValue }
            var decoded = [[Float]]()
            for c in 0..<12 {
                var signal = [Float](repeating: 0, count: N + fftN)
                var re = [Float](repeating: 0, count: 1024), ii = re, time = [Float](repeating: 0, count: fftN)
                for t in 0..<frames {
                    let ro = c * rs[1] + t * rs[2], io = c * iss[1] + t * iss[2]
                    for k in 0..<1024 { re[k] = r[ro + k * rs[3]]; ii[k] = im[io + k * iss[3]] }
                    ii[0] = r[ro + 1024 * rs[3]]
                    re.withUnsafeMutableBufferPointer { rb in ii.withUnsafeMutableBufferPointer { ib in
                        var z = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                        vDSP_fft_zrip(fft, &z, 1, 11, FFTDirection(FFT_INVERSE))
                        time.withUnsafeMutableBufferPointer { tb in
                            tb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: 1024) { vDSP_ztoc(&z, 1, $0, 2, 1024) }
                        }
                    } }
                    for i in 0..<fftN { signal[t * hop + i] += time[i] * (1 / Float(fftN)) * window[i] }
                }
                var audio = [Float](repeating: 0, count: valid)
                for i in 0..<valid {
                    let x = signal[i + 1024] / denom[i + 1024]
                    guard x.isFinite else { throw HelperError(code: "SEPARATION_FAILED", message: "nonfinite model output") }
                    audio[i] = x
                }
                if chunk > 0 { for i in 0..<min(overlap, valid) { let w = Float(i) / Float(overlap); audio[i] = carry[c][i] * (1 - w) + audio[i] * w } }
                if valid > step { for i in 0..<(valid - step) { carry[c][i] = audio[step + i] } }
                decoded.append(audio)
            }
            let writeCount = min(step, valid)
            for s in 0..<6 {
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(writeCount))!
                b.frameLength = AVAudioFrameCount(writeCount)
                for c in 0..<2 { decoded[2 * s + c].withUnsafeBufferPointer { b.floatChannelData![c].update(from: $0.baseAddress!, count: writeCount) } }
                try files[s].write(from: b)
            }
            emit(["event": "progress", "completed": chunk + 1, "total": chunks])
        }
    }
    files.removeAll() // Close WAVs so RIFF lengths are final before reporting done.
    emit(["event": "done", "frames": count, "seconds": Date().timeIntervalSince(startTime)])
}

do { try separate() } catch let e as HelperError {
    emit(["event": "error", "code": e.code, "message": e.message]); exit(1)
} catch {
    emit(["event": "error", "code": "SEPARATION_FAILED", "message": error.localizedDescription]); exit(1)
}
