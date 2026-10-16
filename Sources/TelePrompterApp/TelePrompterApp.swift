import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import Speech
import AVFoundation

extension Notification.Name {
    static let restoreEchoPromptWorkspace = Notification.Name("restoreEchoPromptWorkspace")
}

@main
struct EchoPromptApp: App {
    @StateObject private var model = PrompterModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("EchoPrompt") {
            EditorView(model: model)
                .frame(minWidth: 660, minHeight: 520)
        }
        .defaultSize(width: 760, height: 620)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Open Script Studio") {
                    NotificationCenter.default.post(name: .restoreEchoPromptWorkspace, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Makes a Swift Package-launched app behave like a normal Mac app: it gets
/// focus on launch and when its Dock icon is clicked again.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A Dock click should keep a visible floating prompter in presentation
        // mode. Only restore Script Studio if there is no visible prompt.
        let promptIsVisible = NSApp.windows.contains { $0 is NSPanel && $0.isVisible }
        guard !promptIsVisible else {
            // Returning false prevents AppKit's default untitled-window action.
            return false
        }
        NotificationCenter.default.post(name: .restoreEchoPromptWorkspace, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        return false
    }
}

struct SavedScript: Codable, Identifiable, Equatable {
    var id: UUID
    var body: String
    var savedAt: Date
    var fileName: String?
    init(body: String, fileName: String? = nil, savedAt: Date = .now) { self.id = UUID(); self.body = body; self.fileName = fileName; self.savedAt = savedAt }
    var title: String { body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Untitled script" }
}

enum PromptTheme: String, CaseIterable, Identifiable {
    case midnight, paper, ember
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var background: Color { switch self { case .midnight: .black; case .paper: Color(red: 0.96, green: 0.93, blue: 0.84); case .ember: Color(red: 0.15, green: 0.035, blue: 0.02) } }
    var text: Color { self == .paper ? .black : .white }
}

enum StudioAppearance: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

enum PromptControlMode: String, CaseIterable, Identifiable {
    case normal, voice, recordedAudio
    var id: String { rawValue }
    var name: String {
        switch self {
        case .normal: "Normal scrolling"
        case .voice: "Voice control"
        case .recordedAudio: "Recorded audio"
        }
    }
}

/// A presentation-agnostic representation of word-level progress. Both live
/// Voice control and future recorded-audio synchronization can supply this to
/// the renderer without duplicating its visual state rules.
struct PromptReadingProgress: Equatable {
    var confirmedWordIndex: Int
    var predictedWordIndex: Int?
    var dimsCompletedWords: Bool

    static let inactive = PromptReadingProgress(
        confirmedWordIndex: -1,
        predictedWordIndex: nil,
        dimsCompletedWords: false
    )

    static func synchronized(confirmed: Int, predicted: Int?) -> PromptReadingProgress {
        PromptReadingProgress(
            confirmedWordIndex: confirmed,
            predictedWordIndex: predicted,
            dimsCompletedWords: true
        )
    }

    enum WordState: Equatable {
        case completed, current, predicted, upcoming
    }

    func state(for index: Int) -> WordState {
        if dimsCompletedWords, confirmedWordIndex >= 0, index < confirmedWordIndex {
            return .completed
        }
        if index == confirmedWordIndex { return .current }
        if let predictedWordIndex, index == predictedWordIndex { return .predicted }
        return .upcoming
    }
}

/// On-device live transcription for Voice mode. It emits only newly recognized
/// words, so the prompt can ignore filler words that don't occur in the script.
final class VoiceScrollController: NSObject, ObservableObject {
    @Published private(set) var status = "Voice control is ready"
    /// A short, privacy-conscious diagnostic that confirms the recognizer is
    /// receiving speech. It also makes a silent recognizer failure apparent.
    @Published private(set) var heardWords = "Waiting for speech"
    @Published private(set) var newWords: [String] = []
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    /// Fast local voice-activity detection. Unlike transcription, this does
    /// not need to wait for a full word before it can react.
    @Published private(set) var isSpeaking = false

    // Match the language selected for macOS Dictation/Speech Recognition.
    // Hard-coding en-US can otherwise produce no useful results for a Mac
    // configured for another supported English locale.
    private let recognizer = SFSpeechRecognizer(locale: .current)
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionID = UUID()
    private var lastSpeechSignalAt = Date.distantPast
    private var audioBufferCount = 0
    private let speechThreshold: Float = 0.006
    /// Accessing AVAudioEngine.inputNode can itself initiate protected audio
    /// input. Keep track of an installed tap so Normal mode never touches it.
    private var hasActiveAudioTap = false

    func start(context: [String] = []) {
        guard !isListening, !isStarting else { return }
        // `swift run` launches a bare executable, not an app bundle. macOS
        // terminates processes that request protected resources without these
        // purpose strings, so fail safely with a useful development message.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            status = "Voice mode requires the packaged EchoPrompt.app"
            return
        }
        guard recognizer?.isAvailable == true else {
            status = "Speech recognition is currently unavailable"
            return
        }
        isStarting = true
        status = "Requesting speech permission…"
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            requestMicrophoneAccess(context: context, startWhenAuthorized: true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
                DispatchQueue.main.async {
                    guard authorization == .authorized else { self?.fail("Allow Speech Recognition to use Voice mode"); return }
                    self?.requestMicrophoneAccess(context: context, startWhenAuthorized: true)
                }
            }
        case .denied, .restricted:
            fail("Allow Speech Recognition in System Settings")
        @unknown default:
            fail("Speech Recognition permission is unavailable")
        }
    }

    /// Requests protected resources while Script Studio is still visible.
    /// This deliberately does not start audio capture; capture begins only
    /// when the user starts the floating prompter.
    func preparePermissions() {
        guard !isListening, !isStarting else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            status = "Voice mode requires the packaged EchoPrompt.app"
            return
        }
        isStarting = true
        status = "Preparing Voice mode…"
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            requestMicrophoneAccess(context: [], startWhenAuthorized: false)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
                DispatchQueue.main.async {
                    guard authorization == .authorized else {
                        self?.fail("Allow Speech Recognition to use Voice mode")
                        return
                    }
                    self?.requestMicrophoneAccess(context: [], startWhenAuthorized: false)
                }
            }
        case .denied, .restricted:
            fail("Allow Speech Recognition in System Settings")
        @unknown default:
            fail("Speech Recognition permission is unavailable")
        }
    }

    private func requestMicrophoneAccess(context: [String], startWhenAuthorized: Bool) {
        func readyOrStart() {
            if startWhenAuthorized {
                beginSession(context: context)
            } else {
                isStarting = false
                status = "Voice mode is ready"
            }
        }
        status = "Requesting microphone permission…"
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            readyOrStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard granted else { self?.fail("Allow Microphone access to use Voice mode"); return }
                    guard let self else { return }
                    if startWhenAuthorized {
                        self.beginSession(context: context)
                    } else {
                        self.isStarting = false
                        self.status = "Voice mode is ready"
                    }
                }
            }
        case .denied, .restricted:
            fail("Allow Microphone access in System Settings")
        @unknown default:
            fail("Microphone permission is unavailable")
        }
    }

    private func fail(_ message: String) {
        isStarting = false
        isListening = false
        status = message
    }

    func stop() {
        // Ignore delayed callbacks from a task that has just been cancelled.
        sessionID = UUID()
        if hasActiveAudioTap {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            hasActiveAudioTap = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        isStarting = false
        isSpeaking = false
    }

    private func beginSession(context: [String]) {
        let newSessionID = UUID()
        stop()
        sessionID = newSessionID

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Prefer the local recognizer when macOS has a speech model installed.
        // It removes the network round trip and produces partial words sooner.
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        // The script gives the recognizer useful vocabulary (product names,
        // acronyms, and uncommon terms) without sending anything anywhere.
        request.contextualStrings = Array(context.prefix(100))
        self.request = request
        heardWords = "Waiting for speech"
        lastSpeechSignalAt = .distantPast
        audioBufferCount = 0
        isSpeaking = false
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("No microphone input is available")
            return
        }
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            self?.processVoiceActivity(in: buffer, sessionID: newSessionID)
        }
        hasActiveAudioTap = true

        // Create the speech task before audio starts arriving. This is the
        // lifecycle recommended by Apple's Speech sample and avoids dropping
        // the initial spoken phrase while the task is being established.
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.sessionID == newSessionID else { return }
            if let result {
                let words = Self.words(in: result.bestTranscription.formattedString)
                if !words.isEmpty {
                    DispatchQueue.main.async {
                        guard self.sessionID == newSessionID else { return }
                        self.heardWords = words.suffix(5).joined(separator: " ")
                        // Speech can revise early words or append several
                        // words between callbacks. Send an ordered recent
                        // phrase every time; PromptView's forward-only matcher
                        // decides what is genuinely ahead of the cue.
                        self.newWords = Array(words.suffix(8))
                    }
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    guard self.sessionID == newSessionID, self.isListening else { return }
                    self.stop()
                    self.status = "Speech recognition stopped — tap Start voice to retry"
                }
            }
        }
        guard task != nil else {
            fail("Could not start Speech Recognition")
            stop()
            return
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            isStarting = false
            status = "Listening — follow the highlighted word"
        } catch {
            fail("Could not start the microphone")
            stop()
        }
    }

    private func processVoiceActivity(in buffer: AVAudioPCMBuffer, sessionID: UUID) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        let now = Date()
        if rms >= speechThreshold { lastSpeechSignalAt = now }

        // Publish at roughly 20 Hz. The small silence grace window keeps the
        // cue stable between syllables but pauses quickly when speaking stops.
        audioBufferCount += 1
        guard audioBufferCount.isMultiple(of: 4) else { return }
        let speaking = now.timeIntervalSince(lastSpeechSignalAt) < 0.22
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionID == sessionID else { return }
            self.isSpeaking = speaking
        }
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// Local-file playback plus a timestamped Speech transcription. It is separate
/// from VoiceScrollController: Recorded Audio never opens the microphone and
/// advances only according to the selected file's playback time.
final class RecordedAudioController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var status = "Choose an audio file in Script Studio"
    @Published private(set) var isPreparing = false
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentWordIndex = -1

    private struct TimedWord {
        let scriptIndex: Int
        let time: TimeInterval
    }

    /// A recognition segment is usually a single word, but the Speech
    /// framework is also allowed to return a short phrase. Splitting it here
    /// makes the subsequent alignment use the same word granularity as the
    /// prompter rather than treating a phrase as one opaque token.
    private struct TranscriptToken {
        let word: String
        let time: TimeInterval
    }

    private let recognizer = SFSpeechRecognizer(locale: .current)
    private var player: AVAudioPlayer?
    private var request: SFSpeechURLRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var progressTimer: Timer?
    private var timedWords: [TimedWord] = []
    private var preparationID = UUID()
    private var scriptWordCount = 0
    private var audioDuration: TimeInterval = 0

    /// Match Voice mode's consent UX: request Speech Recognition while Script
    /// Studio remains visible, but defer all file work and playback until
    /// presentation begins.
    func preparePermissions() {
        guard !isPreparing else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            status = "Audio synchronization requires the packaged EchoPrompt.app"
            return
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            status = "Audio synchronization is ready"
        case .notDetermined:
            status = "Requesting Speech Recognition permission…"
            SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
                DispatchQueue.main.async {
                    self?.status = authorization == .authorized
                        ? "Audio synchronization is ready"
                        : "Allow Speech Recognition to synchronize audio"
                }
            }
        case .denied, .restricted:
            status = "Allow Speech Recognition to synchronize audio"
        @unknown default:
            status = "Speech Recognition permission is unavailable"
        }
    }

    func prepare(audioURL: URL?, script: String) {
        stop()
        let newPreparationID = UUID()
        preparationID = newPreparationID
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            status = "Audio synchronization requires the packaged EchoPrompt.app"
            return
        }
        guard let audioURL else {
            status = "Choose an audio file in Script Studio"
            return
        }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Add a script before preparing audio"
            return
        }
        guard recognizer?.isAvailable == true else {
            status = "Speech recognition is currently unavailable"
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            self.audioDuration = player.duration
            self.scriptWordCount = Self.words(in: script).count
        } catch {
            status = "Could not open the selected audio file"
            return
        }

        isPreparing = true
        isReady = false
        status = "Preparing audio synchronization…"
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            transcribe(audioURL: audioURL, script: script, preparationID: newPreparationID)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
                DispatchQueue.main.async {
                    guard authorization == .authorized else {
                        self?.finishPreparation("Allow Speech Recognition to synchronize audio")
                        return
                    }
                    self?.transcribe(audioURL: audioURL, script: script, preparationID: newPreparationID)
                }
            }
        case .denied, .restricted:
            finishPreparation("Allow Speech Recognition to synchronize audio")
        @unknown default:
            finishPreparation("Speech Recognition permission is unavailable")
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard isReady, !isPreparing, !timedWords.isEmpty, let player else { return }
        if player.currentTime >= player.duration {
            restart()
        }
        player.play()
        isPlaying = true
        status = "Playing synchronized audio"
        startProgressTimer()
    }

    func pause() {
        player?.pause()
        progressTimer?.invalidate()
        progressTimer = nil
        isPlaying = false
        if !isPreparing { status = "Paused" }
    }

    func restart() {
        player?.pause()
        player?.currentTime = 0
        progressTimer?.invalidate()
        progressTimer = nil
        isPlaying = false
        currentWordIndex = -1
        if !isPreparing { status = timedWords.isEmpty ? status : "Ready — press Play" }
    }

    func stop() {
        // Ignore a final callback from any transcription that was just
        // cancelled because the prompter closed or a new run began.
        preparationID = UUID()
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        task?.cancel()
        request = nil
        task = nil
        timedWords = []
        scriptWordCount = 0
        audioDuration = 0
        isPlaying = false
        isPreparing = false
        isReady = false
        currentWordIndex = -1
    }

    private func transcribe(audioURL: URL, script: String, preparationID: UUID) {
        guard self.preparationID == preparationID else { return }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.contextualStrings = Array(script.split(whereSeparator: { $0.isWhitespace }).prefix(100).map(String.init))
        self.request = request
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result, result.isFinal {
                let timings = self.align(
                    segments: result.bestTranscription.segments,
                    script: script,
                    audioDuration: self.player?.duration ?? 0
                )
                DispatchQueue.main.async {
                    guard self.preparationID == preparationID else { return }
                    self.timedWords = timings
                    self.isPreparing = false
                    self.isReady = !timings.isEmpty
                    self.status = timings.isEmpty
                        ? "Could not match audio to this script"
                        : "Ready — press Play"
                    self.request = nil
                    self.task = nil
                }
            } else if error != nil {
                DispatchQueue.main.async {
                    guard self.preparationID == preparationID else { return }
                    self.finishPreparation("Could not synchronize this audio file")
                }
            }
        }
        if task == nil { finishPreparation("Could not start audio synchronization") }
    }

    private func align(
        segments: [SFTranscriptionSegment],
        script: String,
        audioDuration: TimeInterval
    ) -> [TimedWord] {
        let scriptWords = Self.words(in: script)
        let tokens = Self.tokens(from: segments)
        var scriptIndex = -1
        var result: [TimedWord] = []
        let orderedSegments = segments.sorted(by: { $0.timestamp < $1.timestamp })

        for (tokenIndex, token) in tokens.enumerated() {
            let start = max(0, scriptIndex + 1)
            guard start < scriptWords.count else { break }

            // The expected next word is the only single-token advancement we
            // accept. This keeps a common word (for example "the") or a
            // partially recognised word from silently skipping a sentence.
            if Self.matches(scriptWord: scriptWords[start], spokenWord: token.word) {
                scriptIndex = start
                result.append(TimedWord(scriptIndex: start, time: token.time))
                continue
            }

            // Recognition can omit a word or two. Recover from that only
            // when a later recognised word corroborates the same nearby
            // phrase. This is deliberately more conservative than the old
            // one-word look-ahead: being momentarily behind the recording is
            // preferable to colouring a future paragraph as already read.
            guard token.word.count >= 4 else { continue }
            let end = min(scriptWords.count, start + 5)
            let candidates = scriptWords[start..<end].indices.filter {
                Self.matches(scriptWord: scriptWords[$0], spokenWord: token.word)
                    && Self.hasPhraseConfirmation(
                        tokens: tokens,
                        after: tokenIndex,
                        scriptWords: scriptWords,
                        scriptIndex: $0
                    )
            }
            if candidates.count == 1, let match = candidates.first {
                scriptIndex = match
                result.append(TimedWord(scriptIndex: match, time: token.time))
            }
        }

        // Speech URL recognition normally reports seconds from the start of
        // the file, but its effective timebase can be shorter than the actual
        // AVAudioPlayer duration for certain encoded files. Calibrate only
        // when there is a meaningful discrepancy, so a timing-map defect
        // cannot make the script race through the audio.
        let recognizedEnd = orderedSegments.map { $0.timestamp + $0.duration }.max() ?? 0
        guard audioDuration > 0, recognizedEnd > 0 else { return result }
        let scale = audioDuration / recognizedEnd
        // A few percent over a several-minute recording is already a visible
        // drift. Scale the full map to AVAudioPlayer's actual media duration,
        // which is the same clock used while the audio is playing.
        guard abs(scale - 1) > 0.025 else { return result }
        return result.map {
            TimedWord(
                scriptIndex: $0.scriptIndex,
                time: min(audioDuration, max(0, $0.time * scale))
            )
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
    }

    private func updateProgress() {
        guard let player else { return }
        if !player.isPlaying {
            pause()
            return
        }
        let elapsed = player.currentTime
        let maximumIndex = pacingCeiling(at: elapsed)
        if let word = timedWords.last(where: {
            $0.time <= elapsed && $0.scriptIndex <= maximumIndex
        }), word.scriptIndex > currentWordIndex {
            currentWordIndex = word.scriptIndex
        }
    }

    /// A malformed recognition timeline must never race far ahead of a human
    /// voice. This is a guardrail, not the normal pacing mechanism: normal
    /// progression still comes from each recognised word's timestamp. The
    /// ceiling is generous enough for quick narration while preventing an
    /// invalid map from greying several paragraphs in a few seconds.
    private func pacingCeiling(at elapsed: TimeInterval) -> Int {
        guard audioDuration > 0, scriptWordCount > 0 else { return .max }
        let averageWordsPerSecond = Double(scriptWordCount) / audioDuration
        let maximumWordsPerSecond = max(5.0, averageWordsPerSecond * 2.0)
        let graceWords = 6.0
        return min(
            scriptWordCount - 1,
            Int((elapsed * maximumWordsPerSecond + graceWords).rounded(.down))
        )
    }

    private func finishPreparation(_ message: String) {
        isPreparing = false
        isReady = false
        status = message
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.progressTimer?.invalidate()
            self?.progressTimer = nil
            self?.isPlaying = false
            self?.status = "Finished — press Play to replay"
        }
    }

    private static func tokens(from segments: [SFTranscriptionSegment]) -> [TranscriptToken] {
        segments
            .sorted(by: { $0.timestamp < $1.timestamp })
            .flatMap { segment in
                let words = Self.words(in: segment.substring)
                guard !words.isEmpty else { return [TranscriptToken]() }
                let interval = segment.duration / Double(words.count)
                return words.enumerated().map { index, word in
                    TranscriptToken(
                        word: word,
                        time: segment.timestamp + (Double(index) * interval)
                    )
                }
            }
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func matches(scriptWord: String, spokenWord: String) -> Bool {
        let script = normalized(scriptWord)
        return script == spokenWord || (spokenWord.count >= 4 && script.contains(spokenWord))
    }

    private static func hasPhraseConfirmation(
        tokens: [TranscriptToken],
        after tokenIndex: Int,
        scriptWords: [String],
        scriptIndex: Int
    ) -> Bool {
        let scriptStart = scriptIndex + 1
        let scriptEnd = min(scriptWords.count, scriptStart + 4)
        guard scriptStart < scriptEnd else { return false }

        // One nearby, substantive following word is enough confirmation.
        // We deliberately inspect only a short phrase so a later repeated
        // word cannot validate an otherwise unsafe jump.
        let following = tokens.dropFirst(tokenIndex + 1).prefix(4)
        return following.contains { token in
            token.word.count >= 3
                && scriptWords[scriptStart..<scriptEnd].contains(where: {
                    matches(scriptWord: $0, spokenWord: token.word)
                })
        }
    }
}

@MainActor
final class PrompterModel: ObservableObject {
    @Published var script = "Welcome to EchoPrompt.\n\nPaste your script here, then start EchoPrompt when you are ready."
    @Published var fontSize: Double = 50
    @Published var speed: Double = 24
    @Published var lineSpacing: Double = 1.28
    @Published var opacity: Double = 0.92
    @Published var mirrorText = false
    /// Normal scrolling is deliberately the default; modes are mutually exclusive.
    @Published var controlMode: PromptControlMode = .normal
    @Published var audioFileURL: URL?
    /// Changes whenever the presenter deliberately starts a new run. The
    /// floating window is reused, so this is the explicit reset signal for
    /// its local playback and highlighting state.
    @Published private(set) var presentationSessionID = UUID()
    let voiceScroll = VoiceScrollController()
    let recordedAudio = RecordedAudioController()
    /// Lets the presenter click through the floating prompt onto VS Code.
    @Published var clickThroughPresentation = false {
        didSet { panel?.ignoresMouseEvents = clickThroughPresentation }
    }
    @Published var showRecordingTip = true
    @Published var promptTheme: PromptTheme = .midnight
    @Published var studioAppearance: StudioAppearance = .dark
    @Published private(set) var history: [SavedScript] = []

    private var panel: NSPanel?
    private weak var workspaceWindow: NSWindow?
    private let historyKey = "EchoPrompt.scriptHistory.v1"
    private var activeHistoryID: UUID?

    var promptBackground: Color { promptTheme.background }
    var promptText: Color { promptTheme.text }
    var scriptLibraryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoPrompt Scripts", isDirectory: true)
    }

    private func fileURL(for item: SavedScript) -> URL {
        scriptLibraryURL.appendingPathComponent(item.fileName ?? "\(item.id.uuidString).txt")
    }

    private func fileName(for text: String, excluding itemID: UUID? = nil, currentFileName: String? = nil) -> String {
        let heading = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: " ")
        let invalid = CharacterSet.alphanumerics.union(.whitespaces).inverted
        let safe = heading.components(separatedBy: invalid).joined()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
        let stem = String(safe.prefix(60)).isEmpty ? "EchoPrompt-script" : String(safe.prefix(60))
        var candidate = "\(stem).txt"
        var number = 2
        let used = Set(history.filter { $0.id != itemID }.compactMap(\.fileName))
        while used.contains(candidate) || (candidate != currentFileName && FileManager.default.fileExists(atPath: scriptLibraryURL.appendingPathComponent(candidate).path)) {
            candidate = "\(stem)-\(number).txt"
            number += 1
        }
        return candidate
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: historyKey), let items = try? JSONDecoder().decode([SavedScript].self, from: data) { history = items }
    }

    func saveHistoryNow() {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item: SavedScript
        if let activeHistoryID, let index = history.firstIndex(where: { $0.id == activeHistoryID }) {
            // Preserve the loaded script's identity instead of creating a duplicate.
            let oldURL = fileURL(for: history[index])
            history[index].body = script
            history[index].savedAt = .now
            history[index].fileName = fileName(for: script, excluding: history[index].id, currentFileName: history[index].fileName)
            if oldURL != fileURL(for: history[index]) { try? FileManager.default.removeItem(at: oldURL) }
            item = history[index]
        } else {
            history.removeAll { $0.body == script }
            let saved = SavedScript(body: script, fileName: fileName(for: script))
            history.insert(saved, at: 0)
            activeHistoryID = saved.id
            item = saved
        }
        do {
            try FileManager.default.createDirectory(at: scriptLibraryURL, withIntermediateDirectories: true)
            try script.write(to: fileURL(for: item), atomically: true, encoding: .utf8)
        } catch {
            // The history list remains available even if Finder storage is temporarily unavailable.
        }
        history = Array(history.prefix(20))
        persistHistory()
    }

    func loadHistory(_ item: SavedScript) {
        activeHistoryID = item.id
        script = (try? String(contentsOf: fileURL(for: item), encoding: .utf8)) ?? item.body
    }
    func deleteHistory(_ item: SavedScript) {
        history.removeAll { $0.id == item.id }
        if activeHistoryID == item.id { activeHistoryID = nil }
        try? FileManager.default.removeItem(at: fileURL(for: item))
        persistHistory()
    }
    func revealScriptLibrary() {
        try? FileManager.default.createDirectory(at: scriptLibraryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(scriptLibraryURL)
    }

    func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose recorded audio"
        panel.message = "Choose the recorded audio that EchoPrompt should synchronize with this script."
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { audioFileURL = panel.url }
    }
    private func persistHistory() { if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: historyKey) } }

    func openPrompter() {
        saveHistoryNow()
        // Reopening a retained NSPanel must behave exactly like a first run:
        // no prior scroll position, highlighted word, or live voice session.
        voiceScroll.stop()
        recordedAudio.stop()
        presentationSessionID = UUID()
        workspaceWindow = NSApp.keyWindow
        workspaceWindow?.orderOut(nil)
        if let panel { panel.ignoresMouseEvents = clickThroughPresentation; panel.makeKeyAndOrderFront(nil); return }
        let promptSize = NSSize(width: 900, height: 360)
        // AppKit's coordinate system starts at the bottom. Position the panel
        // 40 points below the usable top edge, near a laptop's camera line.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screen.midX - promptSize.width / 2,
            y: screen.maxY - promptSize.height - 40
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: promptSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "EchoPrompt"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = clickThroughPresentation
        panel.contentView = NSHostingView(rootView: PromptView(model: self))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func closePrompter() {
        voiceScroll.stop()
        recordedAudio.stop()
        panel?.orderOut(nil)
        restoreWorkspace()
    }

    func restoreWorkspace() {
        clickThroughPresentation = false
        workspaceWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct EditorView: View {
    @ObservedObject var model: PrompterModel
    @State private var showSavedScripts = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    HStack(spacing: 11) {
                        Image(systemName: "text.quote")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("EchoPrompt").font(.title2.weight(.bold))
                            Text("Script studio").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { showSavedScripts.toggle() } label: { Label("Saved scripts", systemImage: "bookmark") }
                        .buttonStyle(.bordered)
                        .popover(isPresented: $showSavedScripts, arrowEdge: .bottom) {
                            SavedScriptsPopover(model: model)
                        }
                    Button { model.openPrompter() } label: { Label("Start EchoPrompt", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: [.command])
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Your script").font(.headline); Spacer(); Text("\(model.script.split(whereSeparator: { $0.isWhitespace }).count) words").font(.subheadline).foregroundStyle(.secondary) }
                    TextEditor(text: $model.script)
                        .font(.system(size: 18))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .frame(minHeight: 240, maxHeight: 330)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
                }
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                HStack(alignment: .top, spacing: 14) {
                    EditorCard(title: "Reading pace", icon: "gauge.with.dots.needle.33percent") {
                        ControlLabel(title: "Text size", value: model.fontSize, suffix: " pt")
                        SmoothSlider(value: $model.fontSize, range: 16...110)
                        ControlLabel(title: "Line spacing", value: model.lineSpacing, suffix: "×")
                        SmoothSlider(value: $model.lineSpacing, range: 0.9...2.0)
                        ControlLabel(title: "Scroll speed", value: model.speed, suffix: " px/s")
                        SmoothSlider(value: $model.speed, range: 5...100)
                    }
                    EditorCard(title: "Control mode", icon: "hand.tap.fill") {
                        Picker("Control mode", selection: $model.controlMode) {
                            Text("Normal").tag(PromptControlMode.normal)
                            Text("Voice").tag(PromptControlMode.voice)
                            Text("Audio").tag(PromptControlMode.recordedAudio)
                        }
                        .pickerStyle(.segmented)
                        if model.controlMode == .recordedAudio {
                            HStack {
                                Button("Choose audio file…") { model.chooseAudioFile() }.buttonStyle(.bordered)
                                Text(model.audioFileURL?.lastPathComponent ?? "No file selected")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text("EchoPrompt will transcribe this local file once, then follow its playback word by word.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if model.controlMode == .voice {
                            Text("Access is requested now while Script Studio stays visible. EchoPrompt listens only when you start presenting.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Automatic scrolling with on-screen controls.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Divider().padding(.top, 4)
                        VStack(alignment: .leading, spacing: 5) {
                            Toggle("Click through prompt", isOn: $model.clickThroughPresentation)
                                .font(.subheadline)
                            Text("Useful while working in VS Code. Return via Edit script or EchoPrompt ▸ Open Script Studio (⇧⌘E).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 12)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    EditorCard(title: "Appearance", icon: "paintpalette.fill") {
                        Picker("Prompt theme", selection: $model.promptTheme) {
                            ForEach(PromptTheme.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("Studio appearance", selection: $model.studioAppearance) {
                            ForEach(StudioAppearance.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "command").foregroundStyle(.secondary)
                    Text("Press ⌘↩ to start EchoPrompt in a focused floating window.")
                }.font(.subheadline).foregroundStyle(.secondary)

                if model.showRecordingTip {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "video.badge.checkmark").foregroundStyle(.tint)
                        Text("For recordings, capture your browser or app window—not the floating prompter.")
                            .font(.subheadline)
                        Spacer()
                        Button { model.showRecordingTip = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss recording tip")
                    }
                    .padding(12).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(model.studioAppearance.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .restoreEchoPromptWorkspace)) { _ in
            model.restoreWorkspace()
        }
        .onChange(of: model.controlMode) { mode in
            if mode == .voice {
                model.voiceScroll.preparePermissions()
            } else if mode == .recordedAudio {
                model.recordedAudio.preparePermissions()
            }
        }
    }
}

struct SavedScriptsPopover: View {
    @ObservedObject var model: PrompterModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Saved scripts", systemImage: "bookmark.fill").font(.headline)
                Spacer()
                Button("Reveal in Finder") { model.revealScriptLibrary() }.buttonStyle(.bordered)
            }
            Text("Saved as .txt files in Documents/EchoPrompt Scripts")
                .font(.caption).foregroundStyle(.secondary)
            if model.history.isEmpty {
                Text("Scripts appear here after you start EchoPrompt.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.history) { item in
                            HStack(spacing: 10) {
                                Button { model.loadHistory(item) } label: { Text(item.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
                                    .buttonStyle(.plain)
                                Button { model.deleteHistory(item) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Delete saved script")
                            }.padding(.vertical, 8)
                            if item.id != model.history.last?.id { Divider() }
                        }
                    }
                }.frame(maxHeight: 280)
            }
        }.padding(16).frame(width: 330)
    }
}

struct EditorCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ControlLabel: View {
    let title: String
    let value: Double
    let suffix: String
    var body: some View {
        Text("\(title): \(suffix == "×" ? String(format: "%.2f", value) : String(Int(value)))\(suffix)")
            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
    }
}

/// Explicitly uses an NSSlider without tick marks. The default stepped SwiftUI
/// slider introduces a dotted tick row that distracts from the reading controls.
struct SmoothSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.controlSize = .large
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if slider.doubleValue != value { slider.doubleValue = value }
    }

    final class Coordinator: NSObject {
        var parent: SmoothSlider
        init(_ parent: SmoothSlider) { self.parent = parent }
        @objc func valueChanged(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
}

struct PromptView: View {
    @ObservedObject var model: PrompterModel
    @ObservedObject private var voice: VoiceScrollController
    @ObservedObject private var recordedAudio: RecordedAudioController
    @State private var isPlaying = false
    @State private var showTextAppearance = false
    /// The exact position confirmed by Speech recognition.
    @State private var activeWordIndex = -1
    /// A deliberately bounded, immediate cue driven by microphone activity.
    /// It never gets more than one word ahead of the confirmed position.
    @State private var predictedWordIndex = -1
    @State private var lastScrolledWordIndex = -1
    /// Explicitly resets ScrollViewReader's retained position on a new run.
    @State private var scrollResetToken = UUID()
    @State private var offset: CGFloat = 0
    @State private var lastTick = Date()
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private let baseSpeed: Double = 24
    private let speedSteps: [Double] = [0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0]

    init(model: PrompterModel) {
        self.model = model
        self._voice = ObservedObject(wrappedValue: model.voiceScroll)
        self._recordedAudio = ObservedObject(wrappedValue: model.recordedAudio)
    }

    private var playbackRate: Double { model.speed / baseSpeed }
    private var playbackRateLabel: String { String(format: "%.2f×", playbackRate) }
    private var displayWordIndex: Int {
        switch model.controlMode {
        case .voice:
            max(activeWordIndex, predictedWordIndex)
        case .recordedAudio:
            recordedAudio.currentWordIndex
        case .normal:
            -1
        }
    }
    private var readingProgress: PromptReadingProgress {
        switch model.controlMode {
        case .voice:
            return .synchronized(
                confirmed: activeWordIndex,
                predicted: predictedWordIndex >= 0 ? predictedWordIndex : nil
            )
        case .recordedAudio:
            return .synchronized(confirmed: recordedAudio.currentWordIndex, predicted: nil)
        case .normal:
            return .inactive
        }
    }
    private var controlButtonTitle: String {
        switch model.controlMode {
        case .voice: return voice.isListening ? "Listening" : "Start voice"
        case .recordedAudio:
            return recordedAudio.isPreparing ? "Preparing" : (recordedAudio.isPlaying ? "Pause" : "Play")
        case .normal: return isPlaying ? "Pause" : "Play"
        }
    }
    private var controlButtonDetail: String {
        switch model.controlMode {
        case .voice: return "live follow"
        case .recordedAudio: return recordedAudio.isPreparing ? "syncing words" : "recorded audio"
        case .normal: return playbackRateLabel
        }
    }
    private var controlButtonIcon: String {
        switch model.controlMode {
        case .voice: return "mic.fill"
        case .recordedAudio, .normal:
            return (model.controlMode == .recordedAudio ? recordedAudio.isPlaying : isPlaying) ? "pause.fill" : "play.fill"
        }
    }
    private var footerMessage: String {
        switch model.controlMode {
        case .voice: return "\(voice.status)  •  Heard: \(voice.heardWords)"
        case .recordedAudio: return "\(recordedAudio.status)  •  Esc: close"
        case .normal: return "Space: play or pause   •   Esc: close   •   Reading pace: \(playbackRateLabel)"
        }
    }

    private func changeSpeed(forward: Bool) {
        let current = playbackRate
        if forward {
            let next = speedSteps.first(where: { $0 > current + 0.01 }) ?? speedSteps.last!
            model.speed = next * baseSpeed
        } else {
            let previous = speedSteps.last(where: { $0 < current - 0.01 }) ?? speedSteps.first!
            model.speed = previous * baseSpeed
        }
    }

    private var scriptWords: [String] { model.script.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    private func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func follow(spoken words: [String]) {
        guard !scriptWords.isEmpty else { return }
        var nextIndex = activeWordIndex

        // Consume words in the order they were spoken. A short word such as
        // "the" or "to" may advance only when it is the next expected script
        // word. This prevents common words from causing random jumps.
        for (spokenIndex, spokenWord) in words.enumerated() {
            let target = normalized(spokenWord)
            guard !target.isEmpty else { continue }
            let start = max(0, nextIndex + 1)
            guard start < scriptWords.count else { break }

            if wordsMatch(scriptWords[start], target) {
                nextIndex = start
                continue
            }

            guard target.count >= 4 else { continue }

            // First recover a nearby skipped/misheard word. This is common in
            // partial transcription and is safe because the window is small.
            let nearbyEnd = min(scriptWords.count, start + 8)
            if let match = scriptWords[start..<nearbyEnd].firstIndex(where: { wordsMatch($0, target) }) {
                nextIndex = match
                continue
            }

            // A recognizer may deliver only the tail of a longer phrase after
            // revising its interim transcript. Recover only a short distance
            // and only when the *following* recognized word confirms the same
            // script phrase. A single word is not enough evidence: it caused
            // the previous version to jump across several sentences.
            guard target.count >= 5 else { continue }
            let recoveryEnd = min(scriptWords.count, start + 20)
            let candidates = scriptWords[start..<recoveryEnd].indices.filter { candidate in
                wordsMatch(scriptWords[candidate], target)
                    && hasPhraseConfirmation(
                        spokenWords: words,
                        after: spokenIndex,
                        scriptIndex: candidate
                    )
            }
            if candidates.count == 1, let match = candidates.first {
                nextIndex = match
            }
        }
        // Publish once per recognition result, so the scrolling animation is
        // not restarted for every word in the same spoken phrase.
        if nextIndex != activeWordIndex { activeWordIndex = nextIndex }
    }

    private func wordsMatch(_ scriptWord: String, _ spokenWord: String) -> Bool {
        let expected = normalized(scriptWord)
        return expected == spokenWord || (spokenWord.count >= 4 && expected.contains(spokenWord))
    }

    /// Looks for a second nearby word from the same spoken phrase. It is used
    /// only for short recovery, never for ordinary word-by-word following.
    private func hasPhraseConfirmation(spokenWords: [String], after spokenIndex: Int, scriptIndex: Int) -> Bool {
        let followingWords = spokenWords.dropFirst(spokenIndex + 1)
        let scriptStart = scriptIndex + 1
        let scriptEnd = min(scriptWords.count, scriptStart + 4)
        guard scriptStart < scriptEnd else { return false }

        for followingWord in followingWords {
            let target = normalized(followingWord)
            guard target.count >= 3 else { continue }
            if scriptWords[scriptStart..<scriptEnd].contains(where: { wordsMatch($0, target) }) {
                return true
            }
        }
        return false
    }

    private func updatePredictiveCue() {
        guard model.controlMode == .voice,
              voice.isListening,
              voice.isSpeaking,
              !scriptWords.isEmpty else {
            predictedWordIndex = -1
            return
        }
        // React on microphone activity immediately, but lead the confirmed
        // word by only one position. This improves perceived latency without
        // turning audio-level detection into uncontrolled auto-scrolling.
        predictedWordIndex = min(scriptWords.count - 1, max(0, activeWordIndex + 1))
    }

    private func restartPrompt() {
        offset = 0
        lastTick = Date()
        isPlaying = false
        scrollResetToken = UUID()

        if model.controlMode == .recordedAudio {
            recordedAudio.restart()
            lastScrolledWordIndex = -1
            return
        }
        guard model.controlMode == .voice else { return }
        // A Voice-mode restart is a complete fresh read, not merely a visual
        // scroll reset. Otherwise recognition would continue matching from the
        // previous word and make the top-right button appear ineffective.
        activeWordIndex = -1
        predictedWordIndex = -1
        lastScrolledWordIndex = -1
        voice.stop()
        voice.start(context: scriptWords)
    }

    var body: some View {
        ZStack {
            model.promptBackground.opacity(model.opacity).ignoresSafeArea()
            GeometryReader { proxy in
                ScrollViewReader { reader in
                    ScrollView(.vertical, showsIndicators: false) {
                        PromptWordFlow(
                            words: scriptWords,
                            progress: readingProgress,
                            textColor: model.promptText,
                            fontSize: model.fontSize,
                            lineSpacing: model.lineSpacing
                        )
                            .padding(.horizontal, 56)
                            .padding(.vertical, proxy.size.height * 0.42)
                            .scaleEffect(x: model.mirrorText ? -1 : 1, y: 1)
                            // Normal mode retains its smooth continuous motion.
                            // Voice mode uses the real matched word below.
                            .offset(y: model.controlMode == .normal ? -offset : 0)
                    }
                    // Keep the continuously-scrolling mode gesture-free, but
                    // do not disable the voice ScrollView: doing so can also
                    // suppress ScrollViewReader's programmatic movement on
                    // macOS. Voice mode may additionally be repositioned by
                    // the presenter between spoken passages.
                    .scrollDisabled(model.controlMode == .normal)
                    .onChange(of: displayWordIndex) { index in
                        guard model.controlMode != .normal, index >= 0 else { return }
                        // A predictive cue may disappear during a short pause.
                        // Do not visibly pull the prompt backward in response.
                        guard index >= lastScrolledWordIndex else { return }
                        lastScrolledWordIndex = index
                        // The word views are created by a wrapping Layout.
                        // Waiting one run-loop lets that layout expose the
                        // target ID before attempting to scroll to it.
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.18)) {
                                reader.scrollTo(index, anchor: .center)
                            }
                        }
                    }
                    .onChange(of: scrollResetToken) { _ in
                        // Voice mode's ScrollView keeps its physical position
                        // between runs. Reset it independently of the word
                        // matcher so Restart visibly returns to the beginning.
                        DispatchQueue.main.async {
                            reader.scrollTo(0, anchor: .center)
                        }
                    }
                }
            }
            .clipped()

            VStack(spacing: 0) {
                HStack {
                    Button { model.closePrompter() } label: {
                        Label("Edit script", systemImage: "pencil")
                            .font(.subheadline.weight(.semibold))
                    }
                    .help("Return to the EchoPrompt Script Studio")
                    Spacer()
                    VStack(spacing: 2) {
                        Text(model.controlMode.name.uppercased())
                        Text(
                            model.controlMode == .voice ? voice.status.uppercased()
                                : (model.controlMode == .recordedAudio ? recordedAudio.status.uppercased()
                                    : (isPlaying ? "SCROLLING" : "PAUSED"))
                        )
                    }
                    .font(.caption.bold()).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Button(action: restartPrompt) { Image(systemName: "arrow.counterclockwise") }
                        .help("Restart from the beginning")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.96))
                Spacer()
                VStack(spacing: 10) {
                    GeometryReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                PromptControlButton(
                                    title: "Slower",
                                    detail: model.controlMode == .voice ? "voice paced" : (model.controlMode == .recordedAudio ? "audio paced" : "− speed"),
                                    icon: "tortoise",
                                    isDisabled: model.controlMode != .normal
                                ) { changeSpeed(forward: false) }
                                PromptControlButton(
                                    title: controlButtonTitle,
                                    detail: controlButtonDetail,
                                    icon: controlButtonIcon,
                                    prominent: true,
                                    isDisabled: model.controlMode == .recordedAudio && !recordedAudio.isReady
                                ) {
                                    if model.controlMode == .voice {
                                        voice.isListening ? voice.stop() : voice.start(context: scriptWords)
                                    } else if model.controlMode == .recordedAudio {
                                        recordedAudio.togglePlayback()
                                    } else {
                                        isPlaying.toggle()
                                    }
                                }
                                    .keyboardShortcut(.space, modifiers: [])
                                PromptControlButton(
                                    title: "Faster",
                                    detail: model.controlMode == .voice ? "voice paced" : (model.controlMode == .recordedAudio ? "audio paced" : "+ speed"),
                                    icon: "hare",
                                    isDisabled: model.controlMode != .normal
                                ) { changeSpeed(forward: true) }
                                PromptControlButton(title: "Text", detail: "Aa", icon: "textformat") { showTextAppearance.toggle() }
                                    .popover(isPresented: $showTextAppearance, arrowEdge: .bottom) {
                                        PromptAppearanceInspector(model: model)
                                    }
                                Toggle("Mirror text", isOn: $model.mirrorText)
                                    .toggleStyle(.switch)
                                    .foregroundStyle(.white)
                            }
                            .frame(minWidth: proxy.size.width, alignment: .center)
                            .padding(.horizontal, 2)
                        }
                    }
                    .frame(height: 58)
                    Text(footerMessage)
                        .font(.caption)
                        .foregroundStyle(
                            (model.controlMode == .voice && !voice.isListening)
                                || (model.controlMode == .recordedAudio && !recordedAudio.isReady)
                                ? .orange : .white.opacity(0.7)
                        )
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1) }
                .shadow(color: .black.opacity(0.7), radius: 14, y: -5)
            }
        }
        .onReceive(timer) { now in
            let elapsed = now.timeIntervalSince(lastTick)
            lastTick = now
            if isPlaying && model.controlMode == .normal { offset += CGFloat(model.speed * elapsed) }
        }
        .onReceive(voice.$newWords) { words in
            guard model.controlMode == .voice else { return }
            follow(spoken: words)
            updatePredictiveCue()
        }
        .onChange(of: model.presentationSessionID) { _ in
            isPlaying = false
            activeWordIndex = -1
            predictedWordIndex = -1
            lastScrolledWordIndex = -1
            scrollResetToken = UUID()
            offset = 0
            lastTick = Date()
            showTextAppearance = false
            voice.stop()
            recordedAudio.stop()
            if model.controlMode == .voice {
                voice.start(context: scriptWords)
            } else if model.controlMode == .recordedAudio {
                recordedAudio.prepare(audioURL: model.audioFileURL, script: model.script)
            }
        }
        .onChange(of: voice.isListening) { listening in
            // Each deliberate voice session starts at the beginning, rather
            // than inheriting a cue from a prior run.
            if listening {
                activeWordIndex = -1
                predictedWordIndex = -1
                lastScrolledWordIndex = -1
            }
        }
        .onChange(of: voice.isSpeaking) { _ in
            updatePredictiveCue()
        }
        .onAppear {
            if model.controlMode == .voice {
                activeWordIndex = -1
                predictedWordIndex = -1
                lastScrolledWordIndex = -1
                voice.start(context: scriptWords)
            } else if model.controlMode == .recordedAudio {
                lastScrolledWordIndex = -1
                recordedAudio.prepare(audioURL: model.audioFileURL, script: model.script)
            }
        }
        .onChange(of: model.controlMode) { mode in
            if mode == .voice {
                activeWordIndex = -1
                predictedWordIndex = -1
                lastScrolledWordIndex = -1
                voice.start(context: scriptWords)
            } else if mode == .recordedAudio {
                voice.stop()
                activeWordIndex = -1
                predictedWordIndex = -1
                lastScrolledWordIndex = -1
                recordedAudio.prepare(audioURL: model.audioFileURL, script: model.script)
            } else {
                voice.stop()
                recordedAudio.stop()
                predictedWordIndex = -1
            }
        }
        .onExitCommand { model.closePrompter() }
    }
}

/// Places every script word as an individually addressable view. That is the
/// key difference from a single concatenated Text: voice mode can scroll to
/// the exact spoken word and reliably apply its orange underline.
struct PromptWordFlow: View {
    let words: [String]
    let progress: PromptReadingProgress
    let textColor: Color
    let fontSize: Double
    let lineSpacing: Double

    var body: some View {
        FlowLayout(
            horizontalSpacing: max(8, CGFloat(fontSize * 0.22)),
            verticalSpacing: max(8, CGFloat(fontSize * lineSpacing - fontSize))
        ) {
            ForEach(Array(words.enumerated()), id: \.offset) { item in
                let state = progress.state(for: item.offset)
                Text(item.element)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(color(for: state))
                    .underline(
                        state == .current || state == .predicted,
                        color: state == .current ? .orange : .orange.opacity(0.55)
                    )
                    .id(item.offset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func color(for state: PromptReadingProgress.WordState) -> Color {
        switch state {
        case .completed:
            // Softer than upcoming text while remaining readable on every
            // selected prompt theme, including Paper.
            textColor.opacity(0.46)
        case .current:
            .orange
        case .predicted:
            .orange.opacity(0.65)
        case .upcoming:
            textColor
        }
    }
}

/// A compact wrapping layout for individually addressable script words.
/// SwiftUI's Text concatenation cannot expose word-level scroll targets.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let requiredWidth = x == 0 ? size.width : horizontalSpacing + size.width
            if x > 0, x + requiredWidth > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += size.width + (x > 0 ? horizontalSpacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Assemble rows first so each line remains optically centered, matching
        // the previous centred teleprompter text rather than becoming a left-
        // aligned collection of individual word views.
        var rows: [[Int]] = [[]]
        var rowWidths: [CGFloat] = [0]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let spacing = rows[rows.count - 1].isEmpty ? 0 : horizontalSpacing
            if !rows[rows.count - 1].isEmpty, rowWidths[rowWidths.count - 1] + spacing + size.width > bounds.width {
                rows.append([index])
                rowWidths.append(size.width)
            } else {
                rows[rows.count - 1].append(index)
                rowWidths[rowWidths.count - 1] += spacing + size.width
            }
        }

        var y = bounds.minY
        for (rowIndex, row) in rows.enumerated() {
            var x = bounds.midX - rowWidths[rowIndex] / 2
            var rowHeight: CGFloat = 0
            for index in row {
                let subview = subviews[index]
                let size = subview.sizeThatFits(.unspecified)
                subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + horizontalSpacing
                rowHeight = max(rowHeight, size.height)
            }
            y += rowHeight + verticalSpacing
        }
    }
}

/// A small, temporary live inspector. It is anchored to the Text control rather
/// than becoming another opaque layer across the reading surface.
struct PromptAppearanceInspector: View {
    @ObservedObject var model: PrompterModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Text size \(Int(model.fontSize)) pt").font(.caption.weight(.semibold))
                SmoothSlider(value: $model.fontSize, range: 16...110)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Line spacing \(String(format: "%.2f", model.lineSpacing))×").font(.caption.weight(.semibold))
                SmoothSlider(value: $model.lineSpacing, range: 0.9...2.0)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct PromptControlButton: View {
    let title: String
    let detail: String
    let icon: String
    var prominent = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.body.weight(.bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.bold))
                    Text(detail).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                }
            }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(prominent ? Color.accentColor : Color(red: 0.22, green: 0.22, blue: 0.24), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .accessibilityLabel(title)
    }
}

struct SettingsView: View {
    @ObservedObject var model: PrompterModel
    var body: some View {
        Form {
            Slider(value: $model.opacity, in: 0.25...1) { Text("Prompt background opacity") }
            Toggle("Show recording-safe guidance", isOn: $model.showRecordingTip)
        }.padding().frame(width: 390)
    }
}
