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

// MARK: - Prompt placement

enum PromptPlacement: String, CaseIterable, Identifiable {
    case notch, corner, floating
    var id: String { rawValue }
    var name: String {
        switch self {
        case .notch: "Notch"
        case .corner: "Corner"
        case .floating: "Floating"
        }
    }
    var icon: String {
        switch self {
        case .notch: "laptopcomputer"
        case .corner: "rectangle.inset.topright.filled"
        case .floating: "macwindow"
        }
    }
}

enum PromptCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var name: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

/// How PromptView arranges itself. Derived from the placement and panel size;
/// never persisted.
enum PromptLayoutStyle { case full, compact, notch }

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
        // Otherwise the stale "Listening…" text would outlive the microphone.
        if isListening { status = "Microphone off" }
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

    // MARK: Capture visibility & placement settings

    /// Best-effort: the capturing app decides whether it honours
    /// `sharingType = .none` (ScreenCaptureKit is inconsistent about it).
    @Published var hideFromScreenCapture = true {
        didSet {
            UserDefaults.standard.set(hideFromScreenCapture, forKey: DefaultsKey.hideFromCapture)
            applyCaptureVisibility()
        }
    }
    @Published var placement: PromptPlacement = .floating {
        didSet {
            UserDefaults.standard.set(placement.rawValue, forKey: DefaultsKey.placement)
            placementSettingsChanged()
        }
    }
    @Published var corner: PromptCorner = .topRight {
        didSet {
            UserDefaults.standard.set(corner.rawValue, forKey: DefaultsKey.corner)
            placementSettingsChanged()
        }
    }
    @Published var cornerSize = CGSize(width: 420, height: 240) {
        didSet { Self.store(cornerSize, forKey: DefaultsKey.cornerSize) }
    }
    /// Width of the notch panel and height of its body below the notch.
    @Published var notchSize = CGSize(width: 560, height: 150) {
        didSet { Self.store(notchSize, forKey: DefaultsKey.notchSize) }
    }
    /// `nil` means "the display Script Studio is on".
    @Published var targetDisplayID: String? {
        didSet {
            UserDefaults.standard.set(targetDisplayID, forKey: DefaultsKey.targetDisplay)
            placementSettingsChanged()
        }
    }
    @Published var notchTipDismissed = false {
        didSet { UserDefaults.standard.set(notchTipDismissed, forKey: DefaultsKey.notchTipDismissed) }
    }
    /// Height of the hardware notch on the prompt's display; 0 when the
    /// notch placement falls back to top-center docking.
    @Published private(set) var notchTopInset: CGFloat = 0

    private var panel: PromptPanel?
    private let panelDelegate = PromptPanelDelegate()
    private weak var workspaceWindow: NSWindow?
    private let historyKey = "EchoPrompt.scriptHistory.v1"
    private var activeHistoryID: UUID?
    /// Floating frames per display, stored relative to that display's origin.
    private var floatingFrames: [String: NSRect] = [:]
    private var studioScreenKey: String?
    private var isApplyingPlacement = false
    private var suppressAutoApply = false
    private var pendingPanelWork: DispatchWorkItem?
    private var notchResizeStart: (height: CGFloat, mouseY: CGFloat)?

    private enum DefaultsKey {
        static let hideFromCapture = "EchoPrompt.hideFromCapture.v1"
        static let placement = "EchoPrompt.placement.v1"
        static let corner = "EchoPrompt.corner.v1"
        static let cornerSize = "EchoPrompt.cornerSize.v1"
        static let notchSize = "EchoPrompt.notchSize.v1"
        static let floatingFrames = "EchoPrompt.floatingFrames.v1"
        static let targetDisplay = "EchoPrompt.targetDisplay.v1"
        static let notchTipDismissed = "EchoPrompt.notchTipDismissed.v1"
        static let clickThroughHintShown = "EchoPrompt.clickThroughHintShown.v1"
    }

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

        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKey.hideFromCapture) != nil {
            hideFromScreenCapture = defaults.bool(forKey: DefaultsKey.hideFromCapture)
        }
        if let raw = defaults.string(forKey: DefaultsKey.placement), let value = PromptPlacement(rawValue: raw) { placement = value }
        if let raw = defaults.string(forKey: DefaultsKey.corner), let value = PromptCorner(rawValue: raw) { corner = value }
        if let size = Self.loadSize(forKey: DefaultsKey.cornerSize) { cornerSize = size }
        if let size = Self.loadSize(forKey: DefaultsKey.notchSize) { notchSize = size }
        targetDisplayID = defaults.string(forKey: DefaultsKey.targetDisplay)
        notchTipDismissed = defaults.bool(forKey: DefaultsKey.notchTipDismissed)
        if let stored = defaults.dictionary(forKey: DefaultsKey.floatingFrames) as? [String: String] {
            floatingFrames = stored.mapValues { NSRectFromString($0) }
        }

        _ = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.screensDidChange() }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.activeSpaceDidChange() }
        }
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
        // Script Studio's display is the default prompt display.
        studioScreenKey = workspaceWindow?.screen.map(Self.displayKey(for:))
        workspaceWindow?.orderOut(nil)
        let panel = self.panel ?? makePanel()
        // Set before ordering front: some capture tools snapshot the window
        // list when a stream starts.
        applyCaptureVisibility()
        applyPlacement(animated: false)
        panel.ignoresMouseEvents = clickThroughPresentation
        panel.makeKeyAndOrderFront(nil)
    }

    func closePrompter() {
        voiceScroll.stop()
        recordedAudio.stop()
        pendingPanelWork?.cancel()
        notchResizeStart = nil
        panel?.orderOut(nil)
        restoreWorkspace()
    }

    /// The panel is created once and only ever reconfigured, so PromptView's
    /// reading state survives placement changes.
    private func makePanel() -> PromptPanel {
        let panel = PromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 360),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "EchoPrompt"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panelDelegate.model = self
        panel.delegate = panelDelegate
        let hostingView = NSHostingView(rootView: PromptView(model: self))
        // The model owns the frame; SwiftUI content must not resize the panel.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    // MARK: Capture visibility

    var captureSharingType: NSWindow.SharingType { hideFromScreenCapture ? .none : .readOnly }

    func applyCaptureVisibility() {
        panel?.sharingType = captureSharingType
    }

    var shouldShowClickThroughHint: Bool {
        clickThroughPresentation && placement != .floating
            && !UserDefaults.standard.bool(forKey: DefaultsKey.clickThroughHintShown)
    }

    func markClickThroughHintShown() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.clickThroughHintShown)
    }

    /// Notch placement is always black; theme text without contrast on black
    /// (Paper's black text) falls back to white.
    var notchTextColor: Color { promptTheme == .paper ? .white : promptTheme.text }

    // MARK: Displays

    static func displayKey(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "\(number?.uint32Value ?? 0)|\(screen.localizedName)"
    }

    /// Display IDs can change after a reboot or dock reconnect, so fall back
    /// to the display name.
    private func screen(forKey key: String?) -> NSScreen? {
        guard let key else { return nil }
        let screens = NSScreen.screens
        if let exact = screens.first(where: { Self.displayKey(for: $0) == key }) { return exact }
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        if let id = parts.first, let byID = screens.first(where: { Self.displayKey(for: $0).hasPrefix(id + "|") }) { return byID }
        if parts.count == 2 { return screens.first { $0.localizedName == parts[1] } }
        return nil
    }

    var availableDisplays: [(key: String, name: String)] {
        NSScreen.screens.map { (Self.displayKey(for: $0), $0.localizedName) }
    }

    func isDisplayConnected(_ key: String) -> Bool { screen(forKey: key) != nil }

    private func presentationScreen() -> NSScreen? {
        screen(forKey: targetDisplayID) ?? screen(forKey: studioScreenKey) ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The display Studio describes before a presentation starts.
    private var previewScreen: NSScreen? {
        screen(forKey: targetDisplayID)
            ?? NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible })?.screen
            ?? NSScreen.main
    }

    var previewScreenHasNotch: Bool { (previewScreen?.safeAreaInsets.top ?? 0) > 0 }
    var anyScreenHasNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }

    private func screensDidChange() {
        // Refresh Studio's display picker and notch caption.
        objectWillChange.send()
        guard panel?.isVisible == true else { return }
        applyPlacement(animated: false)
    }

    private func activeSpaceDidChange() {
        guard let panel, panel.isVisible, placement == .notch else { return }
        applyPlacement(animated: false)
        panel.orderFrontRegardless()
    }

    // MARK: Placement geometry

    private static func hardwareNotchWidth(on screen: NSScreen) -> CGFloat? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        return max(0, screen.frame.width - left.width - right.width)
    }

    private func notchFrame(on screen: NSScreen) -> NSRect {
        let inset = screen.safeAreaInsets.top
        let hardwareWidth = Self.hardwareNotchWidth(on: screen) ?? 0
        let width = min(screen.frame.width, max(notchSize.width, hardwareWidth + 2 * 60))
        let height = inset + notchSize.height
        // Without a notch, dock under the menu bar instead of the physical top.
        let top = inset > 0 ? screen.frame.maxY : screen.visibleFrame.maxY
        return NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height)
    }

    private func clampedCornerSize(on screen: NSScreen) -> CGSize {
        let visible = screen.visibleFrame
        return CGSize(
            width: min(max(cornerSize.width, 300), visible.width * 0.6),
            height: min(max(cornerSize.height, 160), visible.height * 0.6)
        )
    }

    private func cornerFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let size = clampedCornerSize(on: screen)
        let margin: CGFloat = 16
        return NSRect(
            x: corner.isLeft ? visible.minX + margin : visible.maxX - margin - size.width,
            y: corner.isTop ? visible.maxY - margin - size.height : visible.minY + margin,
            width: size.width,
            height: size.height
        )
    }

    private func floatingFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        var frame: NSRect
        if let saved = floatingFrames[Self.displayKey(for: screen)] {
            frame = saved.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        } else {
            // AppKit's coordinate system starts at the bottom. Position the
            // panel 40 points below the usable top edge, near the camera line.
            let size = NSSize(width: 900, height: 360)
            frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 40, width: size.width, height: size.height)
        }
        // Keep at least 80 × 40 points reachable after display changes.
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX - frame.width + 80), visible.maxX - 80)
        frame.origin.y = min(max(frame.minY, visible.minY - frame.height + 40), visible.maxY - frame.height)
        return frame
    }

    // MARK: Applying placement

    func applyPlacement(animated: Bool) {
        guard let panel, let screen = presentationScreen() else { return }
        let frame: NSRect
        switch placement {
        case .notch:
            notchTopInset = screen.safeAreaInsets.top
            frame = notchFrame(on: screen)
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
            panel.allowsMenuBarOverlap = true
            panel.isMovableByWindowBackground = false
            panel.hasShadow = false
            // Only the bottom handle resizes the notch body.
            panel.minSize = frame.size
            panel.maxSize = frame.size
        case .corner:
            notchTopInset = 0
            frame = cornerFrame(on: screen)
            panel.level = .floating
            panel.allowsMenuBarOverlap = false
            panel.isMovableByWindowBackground = true
            panel.hasShadow = true
            panel.minSize = NSSize(width: 300, height: 160)
            panel.maxSize = NSSize(width: screen.visibleFrame.width * 0.6, height: screen.visibleFrame.height * 0.6)
        case .floating:
            notchTopInset = 0
            frame = floatingFrame(on: screen)
            panel.level = .floating
            panel.allowsMenuBarOverlap = false
            panel.isMovableByWindowBackground = true
            panel.hasShadow = true
            panel.minSize = NSSize(width: 360, height: 200)
            panel.maxSize = NSSize(width: 10_000, height: 10_000)
        }
        setPanelFrame(frame, animated: animated)
    }

    private func setPanelFrame(_ frame: NSRect, animated: Bool) {
        guard let panel else { return }
        // Programmatic moves must not be mistaken for presenter drags.
        isApplyingPlacement = true
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    self?.isApplyingPlacement = false
                    self?.panel?.invalidateShadow()
                }
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
            isApplyingPlacement = false
        }
    }

    private func placementSettingsChanged() {
        guard !suppressAutoApply, panel?.isVisible == true else { return }
        applyPlacement(animated: true)
    }

    func setNotchWidth(_ width: CGFloat) {
        notchSize.width = width
        placementSettingsChanged()
    }

    /// Driven by the notch body's bottom handle. Uses the global mouse
    /// position because the handle moves while the panel grows.
    func updateNotchHeightDrag() {
        let mouseY = NSEvent.mouseLocation.y
        if notchResizeStart == nil { notchResizeStart = (notchSize.height, mouseY) }
        guard let start = notchResizeStart, let panel, let screen = presentationScreen() else { return }
        notchSize.height = min(max(start.height + (start.mouseY - mouseY), 80), 400)
        let frame = notchFrame(on: screen)
        panel.minSize = frame.size
        panel.maxSize = frame.size
        setPanelFrame(frame, animated: false)
    }

    func endNotchHeightDrag() { notchResizeStart = nil }

    // MARK: Presenter moves & resizes

    func panelDidMove() {
        guard !isApplyingPlacement, let panel, panel.isVisible else { return }
        switch placement {
        case .floating: schedulePanelWork(after: 0.3) { [weak self] in self?.saveFloatingFrame() }
        case .corner: schedulePanelWork(after: 0.15) { [weak self] in self?.snapToNearestCorner() }
        case .notch: break
        }
    }

    func panelDidEndLiveResize() {
        guard !isApplyingPlacement, let panel, panel.isVisible else { return }
        switch placement {
        case .floating: saveFloatingFrame()
        case .corner:
            cornerSize = panel.frame.size
            snapToNearestCorner()
        case .notch: break
        }
    }

    private func schedulePanelWork(after delay: TimeInterval, _ work: @escaping () -> Void) {
        pendingPanelWork?.cancel()
        let item = DispatchWorkItem(block: work)
        pendingPanelWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func saveFloatingFrame() {
        guard placement == .floating, let panel, let screen = panel.screen else { return }
        floatingFrames[Self.displayKey(for: screen)] = panel.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        UserDefaults.standard.set(floatingFrames.mapValues { NSStringFromRect($0) }, forKey: DefaultsKey.floatingFrames)
    }

    private func snapToNearestCorner() {
        // Snap only once the presenter has released the mouse.
        guard NSEvent.pressedMouseButtons == 0 else {
            schedulePanelWork(after: 0.15) { [weak self] in self?.snapToNearestCorner() }
            return
        }
        guard placement == .corner, let panel, panel.isVisible,
              let screen = panel.screen ?? presentationScreen() else { return }
        let visible = screen.visibleFrame
        let isLeft = panel.frame.midX < visible.midX
        let isTop = panel.frame.midY > visible.midY
        suppressAutoApply = true
        corner = isTop ? (isLeft ? .topLeft : .topRight) : (isLeft ? .bottomLeft : .bottomRight)
        let key = Self.displayKey(for: screen)
        if presentationScreen().map(Self.displayKey(for:)) != key { targetDisplayID = key }
        suppressAutoApply = false
        applyPlacement(animated: true)
    }

    private static func loadSize(forKey key: String) -> CGSize? {
        guard let values = UserDefaults.standard.array(forKey: key) as? [Double], values.count == 2 else { return nil }
        return CGSize(width: values[0], height: values[1])
    }

    private static func store(_ size: CGSize, forKey key: String) {
        UserDefaults.standard.set([Double(size.width), Double(size.height)], forKey: key)
    }

    func restoreWorkspace() {
        clickThroughPresentation = false
        workspaceWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Prompt panel

/// The borderless, non-activating window that hosts PromptView in every
/// placement. Clicking it during a call does not bring Script Studio forward.
final class PromptPanel: NSPanel {
    /// Notch placement sits over the menu bar, which AppKit otherwise prevents.
    var allowsMenuBarOverlap = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsMenuBarOverlap ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

final class PromptPanelDelegate: NSObject, NSWindowDelegate {
    weak var model: PrompterModel?
    func windowDidMove(_ notification: Notification) { model?.panelDidMove() }
    func windowDidEndLiveResize(_ notification: Notification) { model?.panelDidEndLiveResize() }
    func windowDidChangeScreen(_ notification: Notification) { model?.applyCaptureVisibility() }
}

/// Popovers create their own windows, which do not inherit the prompt panel's
/// sharingType. Attach this to their content to hide them from capture too.
struct CaptureVisibilityProbe: NSViewRepresentable {
    let hidesFromCapture: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.hidesFromCapture = hidesFromCapture
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) { view.hidesFromCapture = hidesFromCapture }

    final class ProbeView: NSView {
        var hidesFromCapture = true { didSet { apply() } }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        private func apply() { window?.sharingType = hidesFromCapture ? .none : .readOnly }
    }
}

/// Square top edge with a slight outward flare and rounded bottom corners, so
/// the prompt reads as one surface with the hardware notch.
struct NotchShape: Shape {
    static let flare: CGFloat = 8
    var bottomRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let f = Self.flare
        let r = min(bottomRadius, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.minY + f), control: CGPoint(x: rect.maxX - f, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY), control: CGPoint(x: rect.maxX - f, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + f + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.maxY - r), control: CGPoint(x: rect.minX + f, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + f, y: rect.minY + f))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: rect.minX + f, y: rect.minY))
        path.closeSubpath()
        return path
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
                    EditorCard(title: "Prompt behaviour", icon: "sparkles") {
                        Text("Choose how EchoPrompt follows your script.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Follow mode", selection: $model.controlMode) {
                            Text("Normal").tag(PromptControlMode.normal)
                            Text("Voice").tag(PromptControlMode.voice)
                            Text("Audio").tag(PromptControlMode.recordedAudio)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Follow mode")
                        if model.controlMode == .recordedAudio {
                            HStack(spacing: 10) {
                                Image(systemName: "waveform")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.audioFileURL?.lastPathComponent ?? "No recording selected")
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(model.audioFileURL == nil ? "Select a local recording to synchronize." : "Local audio source")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Button(model.audioFileURL == nil ? "Choose…" : "Change…") {
                                    model.chooseAudioFile()
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))

                            Label("EchoPrompt transcribes the recording once, then follows its playback word by word.", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if model.controlMode == .voice {
                            Label("Voice access is requested here. EchoPrompt listens only after you start presenting.", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Smooth automatic scrolling, with pace controls in the prompter.", systemImage: "arrow.up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    EditorCard(title: "Presentation", icon: "rectangle.inset.filled.and.cursorarrow") {
                        Picker("Placement", selection: $model.placement) {
                            ForEach(PromptPlacement.allCases) { Label($0.name, systemImage: $0.icon).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        placementDetail
                        if model.availableDisplays.count > 1 {
                            Picker("Display", selection: $model.targetDisplayID) {
                                Text("Same as Script Studio").tag(String?.none)
                                ForEach(model.availableDisplays, id: \.key) { display in
                                    Text(display.name).tag(Optional(display.key))
                                }
                                if let key = model.targetDisplayID, !model.isDisplayConnected(key) {
                                    Text("\(key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? "Display") (disconnected)")
                                        .tag(Optional(key))
                                }
                            }
                        }
                        Toggle(isOn: $model.hideFromScreenCapture) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Hide from screen sharing")
                                    .font(.subheadline.weight(.semibold))
                                Text("Viewers and recordings won't see the prompter in most apps.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        Toggle(isOn: $model.clickThroughPresentation) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Click through prompt")
                                    .font(.subheadline.weight(.semibold))
                                Text("Let clicks pass to the app behind it while you read.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        Label("Return with Edit script or ⇧⌘E.", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
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
                    Text("Press ⌘↩ to start EchoPrompt in your chosen placement.")
                }.font(.subheadline).foregroundStyle(.secondary)

                if model.anyScreenHasNotch && model.placement != .notch && !model.notchTipDismissed {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "laptopcomputer").foregroundStyle(.tint)
                        Text("Try Notch placement: read right under your camera.")
                            .font(.subheadline)
                        Spacer()
                        Button("Use Notch") {
                            model.placement = .notch
                            model.notchTipDismissed = true
                        }
                        Button { model.notchTipDismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss notch tip")
                    }
                    .padding(12).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                }

                if model.showRecordingTip {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "video.badge.checkmark").foregroundStyle(.tint)
                        Text(model.hideFromScreenCapture
                             ? "EchoPrompt is hidden from screen sharing. Do a 10-second test recording in your meeting app before going live."
                             : "For recordings, capture your browser or app window—not the floating prompter.")
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

    @ViewBuilder private var placementDetail: some View {
        switch model.placement {
        case .notch:
            Label(
                model.previewScreenHasNotch
                    ? "Sits under the camera notch."
                    : "No notch on this display. Will dock at top center.",
                systemImage: "camera"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if !model.clickThroughPresentation {
                Label("Covers part of the menu bar while presenting.", systemImage: "menubar.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .corner:
            HStack(spacing: 10) {
                CornerPicker(selection: $model.corner)
                Text(model.corner.name).font(.caption).foregroundStyle(.secondary)
            }
        case .floating:
            Label("Move and resize it anywhere. Its position is remembered per display.", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A 2×2 miniature screen for choosing the prompter corner.
struct CornerPicker: View {
    @Binding var selection: PromptCorner

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow { cell(.topLeft); cell(.topRight) }
            GridRow { cell(.bottomLeft); cell(.bottomRight) }
        }
        .padding(4)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18)))
    }

    private func cell(_ corner: PromptCorner) -> some View {
        Button { selection = corner } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(selection == corner ? Color.accentColor : Color.primary.opacity(0.10))
                .frame(width: 30, height: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(corner.name)
        .help(corner.name)
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
    /// Where Voice and Recorded modes want `offset` to be. Only ever moves
    /// forward; `offset` glides toward it every frame instead of jumping.
    @State private var followTarget: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastTick = Date()
    @State private var hoverBarVisible = false
    /// Invalidates pending hide-after-delay work when the pointer re-enters.
    @State private var hoverToken = UUID()
    @State private var showClickThroughHint = false
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
        case .voice: return voice.isStarting ? "Starting" : (voice.isListening ? "Listening" : "Start voice")
        case .recordedAudio:
            return recordedAudio.isPreparing ? "Preparing" : (recordedAudio.isPlaying ? "Pause" : "Play")
        case .normal: return isPlaying ? "Pause" : "Play"
        }
    }
    private var controlButtonDetail: String {
        switch model.controlMode {
        case .voice:
            if voice.isListening { return voice.isSpeaking ? "hearing you" : "waiting for speech" }
            return voice.isStarting ? "preparing mic" : "tap to start"
        case .recordedAudio: return recordedAudio.isPreparing ? "syncing words" : "recorded audio"
        case .normal: return playbackRateLabel
        }
    }
    private var controlButtonIcon: String {
        switch model.controlMode {
        case .voice: return voice.isStarting ? "mic" : (voice.isListening ? "mic.fill" : "mic.slash.fill")
        case .recordedAudio, .normal:
            return (model.controlMode == .recordedAudio ? recordedAudio.isPlaying : isPlaying) ? "pause.fill" : "play.fill"
        }
    }
    /// Short state for the header, derived from the microphone itself so it
    /// can never describe a state the microphone is not in.
    private var voiceHeadline: String {
        if voice.isStarting { return "Starting microphone…" }
        if voice.isListening { return voice.isSpeaking ? "Hearing you" : "Listening" }
        return "Microphone off"
    }
    private var voiceFooter: String {
        if voice.isStarting { return voice.status }
        if voice.isListening {
            let prefix = voice.isSpeaking ? "Hearing you" : "Listening — start reading your script"
            return "\(prefix)  •  Heard: \(voice.heardWords)"
        }
        let neutral = ["Voice control is ready", "Voice mode is ready"].contains(voice.status) || voice.status.hasPrefix("Microphone off")
        return neutral
            ? "Microphone off  •  Press Space or Start voice to resume listening"
            : "Microphone off  •  \(voice.status)"
    }
    private var footerMessage: String {
        switch model.controlMode {
        case .voice: return voiceFooter
        case .recordedAudio: return "\(recordedAudio.status)  •  Esc: close"
        case .normal: return "Space: play or pause   •   Esc: close   •   Reading pace: \(playbackRateLabel)"
        }
    }

    private var needsAttention: Bool {
        (model.controlMode == .voice && !voice.isListening)
            || (model.controlMode == .recordedAudio && !recordedAudio.isReady)
    }
    private var compactStatus: String {
        switch model.controlMode {
        case .voice: return voiceFooter
        case .recordedAudio: return recordedAudio.status
        case .normal: return "\(isPlaying ? "Scrolling" : "Paused")  •  \(playbackRateLabel)"
        }
    }
    /// The voice button changes colour with the microphone's real state;
    /// other modes keep the accent colour.
    private var primaryTint: Color? {
        guard model.controlMode == .voice else { return nil }
        if voice.isStarting { return .orange }
        return voice.isListening ? Color(red: 0.16, green: 0.62, blue: 0.32) : Color(red: 0.78, green: 0.22, blue: 0.2)
    }
    private var primaryIsPulsing: Bool {
        model.controlMode == .voice && voice.isListening && voice.isSpeaking
    }
    private var primaryAccessibilityValue: String {
        guard model.controlMode == .voice else { return "" }
        if voice.isStarting { return "Starting" }
        return voice.isListening ? (voice.isSpeaking ? "Listening, speech detected" : "Listening") : "Off"
    }
    private var primaryActionDisabled: Bool { model.controlMode == .recordedAudio && !recordedAudio.isReady }

    private func primaryAction() {
        if model.controlMode == .voice {
            voice.isListening ? voice.stop() : voice.start(context: scriptWords)
        } else if model.controlMode == .recordedAudio {
            recordedAudio.togglePlayback()
        } else {
            isPlaying.toggle()
        }
    }

    private func layoutStyle(for size: CGSize) -> PromptLayoutStyle {
        switch model.placement {
        case .notch: return .notch
        case .corner: return .compact
        case .floating: return size.width < 560 || size.height < 260 ? .compact : .full
        }
    }

    private func hoverChanged(_ inside: Bool) {
        hoverToken = UUID()
        if inside {
            withAnimation(.easeOut(duration: 0.15)) { hoverBarVisible = true }
            return
        }
        let token = hoverToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard token == hoverToken, !showTextAppearance else { return }
            withAnimation(.easeOut(duration: 0.15)) { hoverBarVisible = false }
        }
    }

    private func presentClickThroughHintIfNeeded() {
        guard model.shouldShowClickThroughHint else { return }
        model.markClickThroughHintShown()
        withAnimation { showClickThroughHint = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            withAnimation { showClickThroughHint = false }
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
        followTarget = 0

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
        GeometryReader { proxy in
            Group {
                switch layoutStyle(for: proxy.size) {
                case .full: fullLayout
                case .compact: compactLayout
                case .notch: notchLayout
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onHover(perform: hoverChanged)
            .overlay { clickThroughHintView }
        }
        .background(keyboardShortcuts)
        .onReceive(timer) { now in
            let elapsed = now.timeIntervalSince(lastTick)
            lastTick = now
            if isPlaying && model.controlMode == .normal {
                offset += CGFloat(model.speed * elapsed)
            } else if model.controlMode != .normal, abs(followTarget - offset) > 0.05 {
                // Frame-rate independent exponential easing. A short time
                // constant keeps up with speech; Reduce Motion shortens it.
                let timeConstant = reduceMotion ? 0.12 : 0.38
                offset += (followTarget - offset) * CGFloat(1 - exp(-min(elapsed, 0.1) / timeConstant))
            }
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
            followTarget = 0
            lastTick = Date()
            showTextAppearance = false
            hoverBarVisible = false
            presentClickThroughHintIfNeeded()
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
                offset = 0
                followTarget = 0
            }
        }
        .onChange(of: voice.isSpeaking) { _ in
            updatePredictiveCue()
        }
        .onChange(of: model.placement) { _ in presentClickThroughHintIfNeeded() }
        .onAppear {
            presentClickThroughHintIfNeeded()
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
            offset = 0
            followTarget = 0
            isPlaying = false
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

    // MARK: Layouts

    /// Space and Esc stay available in every layout, even when the visible
    /// controls are hidden behind hover.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Play or pause", action: primaryAction)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(primaryActionDisabled)
            Button("Close prompter") { model.closePrompter() }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var surfaceBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
    }

    private var fullLayout: some View {
        ZStack {
            model.promptBackground.opacity(model.opacity).ignoresSafeArea()
            scriptArea(style: .full).clipped()
            VStack(spacing: 0) {
                fullHeader
                Spacer()
                fullControlBar
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(surfaceBorder)
    }

    private var compactLayout: some View {
        ZStack {
            model.promptBackground.opacity(model.opacity)
            scriptArea(style: .compact).clipped()
            VStack {
                Spacer()
                hoverBar.padding(10)
            }
            .opacity(hoverBarVisible ? 1 : 0)
            .allowsHitTesting(hoverBarVisible)
            attentionDot
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(surfaceBorder)
    }

    private var notchLayout: some View {
        ZStack(alignment: .top) {
            // Always opaque black: anything else breaks the notch illusion.
            NotchShape().fill(Color.black)
            VStack(spacing: 0) {
                Color.clear.frame(height: model.notchTopInset)
                ZStack {
                    scriptArea(style: .notch).clipped()
                    VStack {
                        Spacer()
                        hoverBar.padding(.bottom, 4)
                    }
                    .opacity(hoverBarVisible ? 1 : 0)
                    .allowsHitTesting(hoverBarVisible)
                    attentionDot
                }
                notchResizeHandle
            }
            .padding(.horizontal, NotchShape.flare)
        }
        .clipShape(NotchShape())
    }

    private func scriptArea(style: PromptLayoutStyle) -> some View {
        GeometryReader { proxy in
            let topPadding = style == .notch ? proxy.size.height * 0.35 : proxy.size.height * 0.42
            // Where the live word rests: centered, or a bit higher under the notch.
            let anchorY = proxy.size.height * (style == .notch ? 0.4 : 0.5)
            ScrollView(.vertical, showsIndicators: false) {
                PromptWordFlow(
                    words: scriptWords,
                    progress: readingProgress,
                    textColor: style == .notch ? model.notchTextColor : model.promptText,
                    // Small layouts keep at least ~2 lines visible.
                    fontSize: style == .full ? model.fontSize : min(model.fontSize, max(16, proxy.size.height / 3)),
                    lineSpacing: model.lineSpacing
                )
                    .padding(.horizontal, style == .full ? 56 : (style == .notch ? 16 : 20))
                    // The notch keeps the reading line close to the camera,
                    // but leaves room above it so a line stays readable
                    // for a moment before it scrolls out of view.
                    .padding(.top, topPadding)
                    .padding(.bottom, style == .notch ? proxy.size.height : proxy.size.height * 0.42)
                    .scaleEffect(x: model.mirrorText ? -1 : 1, y: 1)
                    // Every mode moves through this one offset: Normal adds
                    // to it at `speed`, Voice and Recorded ease it toward
                    // the spoken word. A ScrollView `scrollTo` could only
                    // snap a whole line at a time, which looked like jumping.
                    .offset(y: -offset)
            }
            .scrollDisabled(true)
            .onPreferenceChange(CurrentWordPositionKey.self) { position in
                guard model.controlMode != .normal, let position else { return }
                // A predictive cue may disappear during a short pause.
                // Never pull the prompt backward in response.
                followTarget = max(followTarget, max(0, topPadding + position.midY - anchorY))
            }
        }
        // Small layouts fade lines out at the top edge instead of cutting
        // them off; the full layout's header already covers that edge.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: style == .full ? 0 : 0.22),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var fullHeader: some View {
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
                    model.controlMode == .voice ? voiceHeadline.uppercased()
                        : (model.controlMode == .recordedAudio ? recordedAudio.status.uppercased()
                            : (isPlaying ? "SCROLLING" : "PAUSED"))
                )
            }
            .font(.caption.bold()).foregroundStyle(.white.opacity(0.9))
            Spacer()
            HStack(spacing: 8) {
                captureBadge
                placementMenu
                Button(action: restartPrompt) { Image(systemName: "arrow.counterclockwise") }
                    .help("Restart from the beginning")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.96))
    }

    private var fullControlBar: some View {
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
                            tint: primaryTint,
                            pulsing: primaryIsPulsing,
                            accessibilityValue: primaryAccessibilityValue,
                            isDisabled: primaryActionDisabled,
                            action: primaryAction
                        )
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
                .foregroundStyle(needsAttention ? .orange : .white.opacity(0.7))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1) }
        .shadow(color: .black.opacity(0.7), radius: 14, y: -5)
    }

    /// Controls for compact and notch layouts; fades in on hover.
    private var hoverBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                HoverIconButton(icon: controlButtonIcon, label: controlButtonTitle, prominent: true, tint: primaryTint, pulsing: primaryIsPulsing, accessibilityValue: primaryAccessibilityValue, isDisabled: primaryActionDisabled, action: primaryAction)
                HoverIconButton(icon: "tortoise", label: "Slower", isDisabled: model.controlMode != .normal) { changeSpeed(forward: false) }
                HoverIconButton(icon: "hare", label: "Faster", isDisabled: model.controlMode != .normal) { changeSpeed(forward: true) }
                HoverIconButton(icon: "arrow.counterclockwise", label: "Restart from the beginning", action: restartPrompt)
                HoverIconButton(icon: "textformat", label: "Text appearance") { showTextAppearance.toggle() }
                    .popover(isPresented: $showTextAppearance, arrowEdge: .bottom) {
                        PromptAppearanceInspector(model: model, showsMirrorToggle: true)
                    }
                placementMenu
                captureBadge
                HoverIconButton(icon: "xmark", label: "Close prompter and edit script") { model.closePrompter() }
            }
            Text(compactStatus)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(needsAttention ? .orange : .white.opacity(0.75))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Keeps warnings visible while the hover bar is hidden.
    @ViewBuilder private var attentionDot: some View {
        if needsAttention {
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
        }
    }

    private var captureBadge: some View {
        HoverIconButton(
            icon: model.hideFromScreenCapture ? "eye.slash.fill" : "eye",
            label: model.hideFromScreenCapture ? "Hidden from screen sharing. Click to show." : "Visible in screen sharing. Click to hide."
        ) { model.hideFromScreenCapture.toggle() }
    }

    @ViewBuilder private func menuItemLabel(_ title: String, checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// A Menu rather than a popover: NSMenu windows are short-lived and
    /// avoid adding another long-lived window that could leak into captures.
    private var placementMenu: some View {
        Menu {
            Button { model.placement = .notch } label: { menuItemLabel("Notch / Top center", checked: model.placement == .notch) }
            Menu("Corner") {
                ForEach(PromptCorner.allCases) { corner in
                    Button {
                        model.corner = corner
                        model.placement = .corner
                    } label: { menuItemLabel(corner.name, checked: model.placement == .corner && model.corner == corner) }
                }
            }
            Button { model.placement = .floating } label: { menuItemLabel("Floating", checked: model.placement == .floating) }
            if model.placement == .notch {
                Divider()
                Menu("Notch width") {
                    ForEach([440, 560, 760], id: \.self) { width in
                        Button { model.setNotchWidth(CGFloat(width)) } label: {
                            menuItemLabel(width == 440 ? "Small" : (width == 560 ? "Medium" : "Large"), checked: Int(model.notchSize.width) == width)
                        }
                    }
                }
            }
            if model.availableDisplays.count > 1 {
                Divider()
                Menu("Display") {
                    Button { model.targetDisplayID = nil } label: { menuItemLabel("Same as Script Studio", checked: model.targetDisplayID == nil) }
                    ForEach(model.availableDisplays, id: \.key) { display in
                        Button { model.targetDisplayID = display.key } label: { menuItemLabel(display.name, checked: model.targetDisplayID == display.key) }
                    }
                }
            }
            Divider()
            Toggle("Hide from screen sharing", isOn: $model.hideFromScreenCapture)
        } label: {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 24)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Prompter placement")
    }

    private var notchResizeHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.3))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .onHover { inside in inside ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in model.updateNotchHeightDrag() }
                    .onEnded { _ in model.endNotchHeightDrag() }
            )
            .accessibilityLabel("Resize prompter height")
    }

    @ViewBuilder private var clickThroughHintView: some View {
        if showClickThroughHint {
            Text("Click-through is on. Use Space / Esc, or ⇧⌘E to return.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.85), in: Capsule())
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// Places every script word as an individually addressable view. That is the
/// key difference from a single concatenated Text: voice mode can scroll to
/// the exact spoken word and reliably apply its orange underline.
struct CurrentWordPosition: Equatable { var index: Int; var midY: CGFloat }

/// Carries the vertical position of the furthest highlighted word, in the
/// word flow's own coordinate space, up to the view that scrolls it.
struct CurrentWordPositionKey: PreferenceKey {
    static var defaultValue: CurrentWordPosition? { nil }
    static func reduce(value: inout CurrentWordPosition?, nextValue: () -> CurrentWordPosition?) {
        guard let next = nextValue() else { return }
        if let current = value, current.index >= next.index { return }
        value = next
    }
}

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
                    .background {
                        // Only the live word measures itself; thousands of
                        // GeometryReaders would be wasteful.
                        if state == .current || state == .predicted {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: CurrentWordPositionKey.self,
                                    value: CurrentWordPosition(index: item.offset, midY: geometry.frame(in: .named("promptFlow")).midY)
                                )
                            }
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .coordinateSpace(name: "promptFlow")
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
    /// Compact layouts have no control bar, so Mirror lives here instead.
    var showsMirrorToggle = false
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
            if showsMirrorToggle {
                Toggle("Mirror text", isOn: $model.mirrorText).toggleStyle(.switch)
            }
        }
        .padding(16)
        .frame(width: 320)
        // The popover is its own window and must be hidden separately.
        .background(CaptureVisibilityProbe(hidesFromCapture: model.hideFromScreenCapture))
    }
}

/// A small icon button for compact and notch layouts. Deliberately has no
/// `.help` tooltip: tooltip windows cannot be hidden from screen capture.
struct HoverIconButton: View {
    let icon: String
    let label: String
    var prominent = false
    var tint: Color?
    var pulsing = false
    var accessibilityValue = ""
    var isDisabled = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(pulsing && !reduceMotion ? 1.18 : 1)
                .frame(width: 28, height: 24)
                .background((prominent ? (tint ?? .accentColor) : Color.white.opacity(0.12)), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(pulsing ? 0.9 : 0), lineWidth: 1.5))
                .animation(.easeInOut(duration: 0.2), value: pulsing)
                .animation(.easeInOut(duration: 0.2), value: tint)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }
}

struct PromptControlButton: View {
    let title: String
    let detail: String
    let icon: String
    var prominent = false
    var tint: Color?
    var pulsing = false
    var accessibilityValue = ""
    var isDisabled = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.body.weight(.bold))
                    .scaleEffect(pulsing && !reduceMotion ? 1.2 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.bold))
                    Text(detail).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                }
            }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(prominent ? (tint ?? .accentColor) : Color(red: 0.22, green: 0.22, blue: 0.24), in: RoundedRectangle(cornerRadius: 9))
                // A white ring shows live speech, not just a colour change.
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(pulsing ? 0.9 : 0), lineWidth: 2))
                .animation(.easeInOut(duration: 0.2), value: pulsing)
                .animation(.easeInOut(duration: 0.2), value: tint)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }
}

struct SettingsView: View {
    @ObservedObject var model: PrompterModel
    var body: some View {
        Form {
            Slider(value: $model.opacity, in: 0.25...1) { Text("Prompt background opacity") }
            Toggle("Show recording-safe guidance", isOn: $model.showRecordingTip)
            Toggle("Hide prompter from screen sharing & recordings", isOn: $model.hideFromScreenCapture)
            Text("Works with most apps; run a test recording before going live. While on, the prompter is also left out of your own screenshots.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding().frame(width: 390)
    }
}
