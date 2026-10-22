// Usage: make_speech <script.txt> <voiceNameSubstring> <rate 0..1> <leadSilenceSec> <outPrefix>
// Renders the script paragraph by paragraph with AVSpeechSynthesizer, resamples to 16 kHz mono,
// and writes <outPrefix>.wav plus <outPrefix>.json with per-script-word start/end seconds.
import AVFoundation
import Foundation

final class D: NSObject, AVSpeechSynthesizerDelegate {
    var frames = 0
    var rate = 22050.0
    var marks: [(NSRange, Double)] = []
    var done = false
    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        marks.append((r, Double(frames) / rate))
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { done = true }
}

let args = CommandLine.arguments
guard args.count >= 6 else { print("usage: gen script voice rate lead out"); exit(2) }
let script = try! String(contentsOfFile: args[1], encoding: .utf8)
let voiceKey = args[2].lowercased()
let rateArg = Float(args[3])!
let lead = Double(args[4])!
let outPrefix = args[5]
let gap = args.count > 6 ? Double(args[6])! : 1.0

let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
let voice = voices.first { $0.name.lowercased().contains(voiceKey) } ?? AVSpeechSynthesisVoice(language: "en-US")!
FileHandle.standardError.write("voice: \(voice.name) \(voice.language) q=\(voice.quality.rawValue)\n".data(using: .utf8)!)

let outRate = 16000.0
var pcm: [Float] = [Float](repeating: 0, count: Int(lead * outRate))
struct W { var word: String; var start: Double; var end: Double }
var words: [W] = []

let paragraphs = script.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

func resample(_ x: [Float], from: Double) -> [Float] {
    let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false)!
    let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate, channels: 1, interleaved: false)!
    let conv = AVAudioConverter(from: src, to: dst)!
    let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(x.count))!
    inBuf.frameLength = AVAudioFrameCount(x.count)
    x.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
    let cap = AVAudioFrameCount(Double(x.count) * outRate / from) + 64
    let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap)!
    var fed = false
    var err: NSError?
    conv.convert(to: out, error: &err) { _, st in
        if fed { st.pointee = .endOfStream; return nil }
        fed = true; st.pointee = .haveData; return inBuf
    }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

for (pi, para) in paragraphs.enumerated() {
    let synth = AVSpeechSynthesizer()
    let d = D()
    synth.delegate = d
    let u = AVSpeechUtterance(string: para)
    u.voice = voice
    u.rate = rateArg
    var raw: [Float] = []
    synth.write(u) { buf in
        guard let b = buf as? AVAudioPCMBuffer, b.frameLength > 0 else { return }
        d.rate = b.format.sampleRate
        d.frames += Int(b.frameLength)
        if let ch = b.floatChannelData?[0] { raw.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(b.frameLength))) }
        else if let ch = b.int16ChannelData?[0] { raw.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(b.frameLength)).map { Float($0) / 32768 }) }
    }
    let t0 = Date()
    while !d.done && Date().timeIntervalSince(t0) < 60 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    precondition(d.done, "synthesis timed out")
    let seg = resample(raw, from: d.rate)
    let base = Double(pcm.count) / outRate

    // whitespace tokens of this paragraph with their char ranges
    let ns = para as NSString
    var tokens: [(String, NSRange)] = []
    var i = 0
    while i < ns.length {
        while i < ns.length, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: i))!) { i += 1 }
        let s = i
        while i < ns.length, !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: i))!) { i += 1 }
        if i > s { tokens.append((ns.substring(with: NSRange(location: s, length: i - s)), NSRange(location: s, length: i - s))) }
    }
    var starts = [Double?](repeating: nil, count: tokens.count)
    for (r, t) in d.marks {
        if let k = tokens.firstIndex(where: { NSLocationInRange(r.location, $0.1) }), starts[k] == nil { starts[k] = base + t }
    }
    // fill gaps by interpolation
    for k in 0..<tokens.count where starts[k] == nil {
        let prev = (0..<k).reversed().compactMap { starts[$0] }.first ?? base
        let next = ((k + 1)..<tokens.count).compactMap { starts[$0] }.first ?? (base + Double(seg.count) / outRate)
        starts[k] = (prev + next) / 2
    }
    let segEnd = base + Double(seg.count) / outRate
    // energy-based end: last 10 ms window above threshold inside [start, nextStart]
    let hop = Int(outRate * 0.01)
    func rms(_ a: Int) -> Float {
        let lo = max(0, a), hi = min(pcm.count + seg.count, a + hop)
        if hi <= lo { return 0 }
        var s: Float = 0
        for n in lo..<hi { let v = n < pcm.count ? pcm[n] : seg[n - pcm.count]; s += v * v }
        return (s / Float(hi - lo)).squareRoot()
    }
    var peak: Float = 0
    var a = pcm.count
    while a < pcm.count + seg.count { peak = max(peak, rms(a)); a += hop }
    let thr = peak * 0.04
    for k in 0..<tokens.count {
        let s = starts[k]!
        let nextS = k + 1 < tokens.count ? starts[k + 1]! : segEnd
        var e = s
        var t = s
        while t < nextS { if rms(Int(t * outRate)) > thr { e = t + 0.01 }; t += 0.01 }
        words.append(W(word: tokens[k].0, start: s, end: max(e, s + 0.05)))
    }
    pcm.append(contentsOf: seg)
    if pi < paragraphs.count - 1 { pcm.append(contentsOf: [Float](repeating: 0, count: Int(gap * outRate))) }
}
pcm.append(contentsOf: [Float](repeating: 0, count: Int(2.5 * outRate)))

// 16-bit WAV
var data = Data()
func put<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
let n = pcm.count
data.append("RIFF".data(using: .ascii)!); put(UInt32(36 + n * 2)); data.append("WAVEfmt ".data(using: .ascii)!)
put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(16000)); put(UInt32(32000)); put(UInt16(2)); put(UInt16(16))
data.append("data".data(using: .ascii)!); put(UInt32(n * 2))
for v in pcm { put(Int16(max(-1, min(1, v)) * 32767)) }
try! data.write(to: URL(fileURLWithPath: outPrefix + ".wav"))

var json = "{\"voice\":\"\(voice.name)\",\"duration\":\(Double(n) / outRate),\"words\":[\n"
json += words.map { "{\"w\":\"\($0.word.replacingOccurrences(of: "\"", with: "\\\""))\",\"s\":\(String(format: "%.3f", $0.start)),\"e\":\(String(format: "%.3f", $0.end))}" }.joined(separator: ",\n")
json += "\n]}\n"
try! json.write(toFile: outPrefix + ".json", atomically: true, encoding: .utf8)
let speechSecs = words.last!.end - words.first!.start
print("\(words.count) words, \(String(format: "%.1f", Double(words.count) / speechSecs * 60)) wpm incl. paragraph pauses, audio \(String(format: "%.1f", Double(n) / outRate))s")
