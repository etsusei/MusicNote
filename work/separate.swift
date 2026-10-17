import Foundation
import CoreML
import Metal
import AVFoundation
import Accelerate

func runProcess(_ executable: String, _ arguments: [String]) throws {
 let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
 try process.run(); process.waitUntilExit()
 if process.terminationStatus != 0 { throw NSError(domain: "musicnote", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey:"Process failed: \(executable)"]) }
}
func separate() throws {
let args = CommandLine.arguments
func option(_ key: String) -> String? { guard let i=args.firstIndex(of:key), i+1<args.count else{return nil}; return args[i+1] }
guard args.contains("--confirm"), let selectedInput=option("--input") else {
 throw NSError(domain:"musicnote", code:1, userInfo:[NSLocalizedDescriptionKey:"Usage: run_separation.py AUDIO --confirm [--output-dir DIR]. Confirmation is required before separation."])
}
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().path
let inputPath = URL(fileURLWithPath:selectedInput).standardizedFileURL.path
let short = args.contains("--short") // Explicit verification mode only; normal runs always process the full song.
let outputDir = option("--output-dir") ?? root + "/output"
let names = ["03_bass", "02_drums", "06_other", "01_vocals", "04_guitar", "05_piano"]
for name in names + ["mp3-export"] {
 let target = outputDir + "/" + name + (name == "mp3-export" ? ".json" : ".mp3")
 guard !FileManager.default.fileExists(atPath:target) else { throw NSError(domain:"musicnote",code:2,userInfo:[NSLocalizedDescriptionKey:"Refusing overwrite: \(target)"]) }
}
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("musicnote-" + UUID().uuidString)
try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:scratch) }
let decodedPath = scratch.appendingPathComponent("input.wav").path
let stemDir = scratch.appendingPathComponent("stems").path
try FileManager.default.createDirectory(atPath:stemDir,withIntermediateDirectories:true)
try runProcess("/opt/homebrew/bin/ffmpeg", ["-v","error","-nostdin","-n","-i",inputPath,"-map","0:a:0","-ar","44100","-ac","2","-c:a","pcm_f32le",decodedPath])
let modelPath = "/Applications/Logic Pro.app/Contents/Resources/MAMachineLearningResources.bundle/Contents/Resources/ke77nsfms3_8024.mlmodelc"
let N = 588800, hop = 512, fftN = 2048, frames = 1151, step = 529920
func log(_ s: String) { print(s); fflush(stdout) }
let source = try AVAudioFile(forReading: URL(fileURLWithPath: decodedPath))
precondition(source.processingFormat.sampleRate == 44100 && source.processingFormat.channelCount == 2)
let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length))!
try source.read(into: input)
let total = Int(input.frameLength)
let count = short ? min(total, N) : total
try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
log("INPUT frames=\(total) duration=\(Double(total)/44100) memoryGB=\(Double(ProcessInfo.processInfo.physicalMemory)/1e9)")
guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain:"musicnote",code:3,userInfo:[NSLocalizedDescriptionKey:"Metal GPU unavailable: run with local GPU access, outside the restricted sandbox"]) }
log("GPU=\(device.name)")
let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU
let startTime = Date()
let model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: config)
log("MODEL_LOADED seconds=\(Date().timeIntervalSince(startTime))")
let fft = vDSP_create_fftsetup(vDSP_Length(11), FFTRadix(kFFTRadix2))!
defer { vDSP_destroy_fftsetup(fft) }
// Match MADSP synthesis: symmetric Hann; model analysis kernels use periodic Hann.
let window = (0..<fftN).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftN-1))) }
var denom = [Float](repeating: 0, count: N + fftN)
for t in 0..<frames { for i in 0..<fftN { denom[t*hop+i] += window[i]*window[i] } }
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
var files: [AVAudioFile] = []
for s in 0..<6 {
 let path = stemDir + "/" + names[s] + ".wav"
 guard !FileManager.default.fileExists(atPath: path) else { fatalError("Refusing overwrite: \(path)") }
 files.append(try AVAudioFile(forWriting: URL(fileURLWithPath:path), settings: [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:44100, AVNumberOfChannelsKey:2, AVLinearPCMBitDepthKey:32, AVLinearPCMIsFloatKey:true, AVLinearPCMIsBigEndianKey:false], commonFormat:.pcmFormatFloat32, interleaved:false))
}
let overlap = N-step
var carry = [[Float]](repeating: [Float](repeating:0,count:overlap), count:12)
let chunks = (count + step - 1) / step
for chunk in 0..<chunks {
 try autoreleasepool {
  let offset = chunk*step
  let valid = min(N,count-offset)
  let a = try MLMultiArray(shape:[1,2,NSNumber(value:N)], dataType:.float32)
  let p = a.dataPointer.assumingMemoryBound(to:Float.self)
  p.initialize(repeating:0,count:2*N)
  for c in 0..<2 { p.advanced(by:c*N).update(from:input.floatChannelData![c].advanced(by:offset),count:valid) }
  let features = try MLDictionaryFeatureProvider(dictionary:["input":a])
  let t0=Date()
  log("PREDICT \(chunk+1)/\(chunks) offset=\(Double(offset)/44100)")
  let prediction = try model.prediction(from:features)
  let real = prediction.featureValue(for:"var_11707")!.multiArrayValue!
  let imag = prediction.featureValue(for:"var_11751")!.multiArrayValue!
  if chunk==0 { log("OUTPUT shape=\(real.shape) strides=\(real.strides)") }
  let r=real.dataPointer.assumingMemoryBound(to:Float.self), im=imag.dataPointer.assumingMemoryBound(to:Float.self)
  let rs=real.strides.map{$0.intValue}, is_=imag.strides.map{$0.intValue}
  var decoded = [[Float]]()
  for c in 0..<12 {
   var signal = [Float](repeating:0,count:N+fftN)
   var re=[Float](repeating:0,count:1024), ii=re, time=[Float](repeating:0,count:fftN)
   for t in 0..<frames {
    let ro=c*rs[1]+t*rs[2], io=c*is_[1]+t*is_[2]
    for k in 0..<1024 { re[k]=r[ro+k*rs[3]]; ii[k]=im[io+k*is_[3]] }
    ii[0]=r[ro+1024*rs[3]]
    re.withUnsafeMutableBufferPointer { rb in ii.withUnsafeMutableBufferPointer { ib in
     var z=DSPSplitComplex(realp:rb.baseAddress!,imagp:ib.baseAddress!)
     vDSP_fft_zrip(fft,&z,1,11,FFTDirection(FFT_INVERSE))
     time.withUnsafeMutableBufferPointer { tb in tb.baseAddress!.withMemoryRebound(to:DSPComplex.self,capacity:1024) { vDSP_ztoc(&z,1,$0,2,1024) } }
    } }
    for i in 0..<fftN { signal[t*hop+i] += time[i]*(1/Float(fftN))*window[i] }
   }
   var audio=[Float](repeating:0,count:valid)
   for i in 0..<valid {
    let x=signal[i+1024]/denom[i+1024]
    guard x.isFinite else { throw NSError(domain:"musicnote",code:4,userInfo:[NSLocalizedDescriptionKey:"Nonfinite model output"]) }
    audio[i]=x
   }
   if chunk>0 { for i in 0..<min(overlap,valid) { let w=Float(i)/Float(overlap); audio[i] = carry[c][i]*(1-w)+audio[i]*w } }
   if valid>step { for i in 0..<(valid-step) {carry[c][i]=audio[step+i]} }
   decoded.append(audio)
  }
  let writeCount = min(step,valid)
  for s in 0..<6 {
   let b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(writeCount))!; b.frameLength=AVAudioFrameCount(writeCount)
   for c in 0..<2 {decoded[2*s+c].withUnsafeBufferPointer { b.floatChannelData![c].update(from:$0.baseAddress!,count:writeCount) } }
   try files[s].write(from:b)
  }
  log("DONE \(chunk+1)/\(chunks) seconds=\(Date().timeIntervalSince(t0)) written=\(min(count,offset+writeCount))")
 }
}
files.removeAll() // Close WAV files and finalize RIFF/data lengths before exiting.
try runProcess("/usr/bin/python3", [root + "/work/export_mp3.py", "--input-dir", stemDir, "--output-dir", outputDir, "--source", inputPath])
log("COMPLETE MP3_192kbps duration=\(Double(count)/44100) elapsed=\(Date().timeIntervalSince(startTime))")

}
do { try separate() } catch { fputs("ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
