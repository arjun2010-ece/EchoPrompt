// Apple on-device recogniser trace, for comparing with sherpa in voice_latency_test.dart.
//
// macOS only. Plays a clip (16 kHz mono WAV from make_speech.swift) into the recogniser in real
// time and writes every hypothesis with its arrival time. Run it from an .app bundle: when
// launched from a terminal or an agent, macOS blames the host app for the speech permission and
// kills the process, and only a bundle with its own NSSpeechRecognitionUsageDescription gets the
// "allow Speech Recognition" prompt (click Allow once; no microphone is used).
//
//   swiftc -O -parse-as-library -swift-version 5 apple_trace.swift -o apple_trace
//   mkdir -p SpeechBench.app/Contents/MacOS && cp apple_trace SpeechBench.app/Contents/MacOS/
//   # SpeechBench.app/Contents/Info.plist needs CFBundleExecutable=apple_trace, a CFBundleIdentifier,
//   # CFBundlePackageType=APPL and NSSpeechRecognitionUsageDescription; then: codesign -s - -f --deep SpeechBench.app
//   open -W -n SpeechBench.app --stdout out.log --stderr err.log --args /abs/clip.wav sfspeech /abs/NAME.sf.json
//
//   sfspeech  SFSpeechRecognizer with requiresOnDeviceRecognition (what the Swift prototype used)
//   analyzer  SpeechAnalyzer / SpeechTranscriber, macOS 26+ (add `--env APPLE_OPTS=fast` to open for
//             .fastResults; APPLE_GROUP=n feeds n*20 ms buffers; APPLE_PREP=1 calls prepareToAnalyze)
// Then run voice_latency_test.dart with VL_APPLE=<dir holding NAME.sf.json / NAME.analyzer.json>.
import AVFoundation
import Foundation
import Speech

struct Event: Codable { var t: Double; var text: String; var final: Bool }

final class Log {
    var events: [Event] = []
    var start = Date()
    let lock = NSLock()
    func add(_ text: String, final: Bool) {
        lock.lock(); defer { lock.unlock() }
        events.append(Event(t: Date().timeIntervalSince(start), text: text, final: final))
    }
}

func loadChunks(_ path: String) throws -> [AVAudioPCMBuffer] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard let all = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { fatalError("alloc") }
    try file.read(into: all)
    precondition(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1, "expected 16 kHz mono")
    var out: [AVAudioPCMBuffer] = []
    let step = 320
    var i = 0
    while i + step <= Int(all.frameLength) {
        let b = AVAudioPCMBuffer(pcmFormat: all.format, frameCapacity: AVAudioFrameCount(step))!
        b.frameLength = AVAudioFrameCount(step)
        memcpy(b.floatChannelData![0], all.floatChannelData![0] + i, step * MemoryLayout<Float>.size)
        out.append(b)
        i += step
    }
    return out
}

/// Sleeps until `t` seconds after `start`.
func wait(until t: Double, since start: Date) async {
    let d = t - Date().timeIntervalSince(start)
    if d > 0.0005 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
}

@available(macOS 26.0, *)
func runAnalyzer(chunks: [AVAudioPCMBuffer], log: Log) async throws {
    var opts: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
    let env = ProcessInfo.processInfo.environment["APPLE_OPTS"] ?? ""
    if env.contains("fast") { opts.insert(.fastResults) }
    let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [], reportingOptions: opts, attributeOptions: [])
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { fatalError("no format") }
    FileHandle.standardError.write("analyzer format: \(fmt)\n".data(using: .utf8)!)
    let conv = AVAudioConverter(from: chunks[0].format, to: fmt)!
    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()

    var finalText = ""
    var volatileText = ""
    let results = Task {
        for try await r in transcriber.results {
            let text = String(r.text.characters)
            if r.isFinal {
                finalText += (finalText.isEmpty ? "" : " ") + text
                volatileText = ""
            } else {
                volatileText = text
            }
            log.add([finalText, volatileText].filter { !$0.isEmpty }.joined(separator: " "), final: r.isFinal)
        }
    }
    if ProcessInfo.processInfo.environment["APPLE_PREP"] != nil { try await analyzer.prepareToAnalyze(in: fmt) }
    try await analyzer.start(inputSequence: stream)
    log.start = Date()
    let group = Int(ProcessInfo.processInfo.environment["APPLE_GROUP"] ?? "1") ?? 1
    var grouped: [AVAudioPCMBuffer] = []
    var gi = 0
    while gi + group <= chunks.count {
        let b = AVAudioPCMBuffer(pcmFormat: chunks[0].format, frameCapacity: AVAudioFrameCount(320 * group))!
        b.frameLength = AVAudioFrameCount(320 * group)
        for j in 0..<group { memcpy(b.floatChannelData![0] + 320 * j, chunks[gi + j].floatChannelData![0], 320 * MemoryLayout<Float>.size) }
        grouped.append(b); gi += group
    }
    for (k, c) in grouped.enumerated() {
        await wait(until: Double((k + 1) * group) * 0.02, since: log.start)   // a chunk exists once it has been recorded
        let cap = AVAudioFrameCount(Double(c.frameLength) * fmt.sampleRate / c.format.sampleRate) + 16
        let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap)!
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return c
        }
        if out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }
    cont.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    _ = try await results.value
}

func runSF(chunks: [AVAudioPCMBuffer], log: Log, contextual: [String]) async throws {
    let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
        SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
    }
    guard status == .authorized else { fatalError("speech recognition not authorized: \(status.rawValue)") }
    let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    req.requiresOnDeviceRecognition = true
    if !contextual.isEmpty { req.contextualStrings = Array(contextual.prefix(100)) }
    let done = DispatchSemaphore(value: 0)
    let task = rec.recognitionTask(with: req) { result, error in
        if let r = result { log.add(r.bestTranscription.formattedString, final: r.isFinal) }
        if result?.isFinal == true || error != nil {
            if let e = error { FileHandle.standardError.write("sf error: \(e)\n".data(using: .utf8)!) }
            done.signal()
        }
    }
    log.start = Date()
    for (k, c) in chunks.enumerated() {
        await wait(until: Double(k + 1) * 0.02, since: log.start)
        req.append(c)
    }
    req.endAudio()
    _ = await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async { _ = done.wait(timeout: .now() + 20); c.resume() }
    }
    task.cancel()
}

@main
struct Main {
    static func main() async {
        let a = CommandLine.arguments
        guard a.count >= 4 else { print("usage: apple_trace clip.wav analyzer|sfspeech out.json [contextual.txt]"); exit(2) }
        do {
            let chunks = try loadChunks(a[1])
            let log = Log()
            if a[2] == "analyzer" {
                if #available(macOS 26.0, *) { try await runAnalyzer(chunks: chunks, log: log) } else { fatalError("needs macOS 26") }
            } else {
                var ctx: [String] = []
                if a.count > 4, let t = try? String(contentsOfFile: a[4], encoding: .utf8) { ctx = t.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
                try await runSF(chunks: chunks, log: log, contextual: ctx)
            }
            let data = try JSONEncoder().encode(["engine": a[2], "clip": a[1]] as [String: String]) // header kept separate
            _ = data
            struct Out: Codable { var engine: String; var clip: String; var events: [Event] }
            try JSONEncoder().encode(Out(engine: a[2], clip: a[1], events: log.events)).write(to: URL(fileURLWithPath: a[3]))
            print("\(log.events.count) events; final: \(log.events.last?.text ?? "")")
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }
}
