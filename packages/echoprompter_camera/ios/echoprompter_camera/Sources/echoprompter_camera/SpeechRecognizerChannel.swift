import AVFoundation
import Flutter
import Speech

/// Voice and Audio mode's recogniser on iOS and iPadOS: Apple's `SFSpeechRecognizer`, on-device where the
/// device supports it for English (otherwise Apple's servers), streaming partial hypotheses to Dart while
/// the event stream is listened to. It is the counterpart of Android's `SpeechChannel`, so Dart treats
/// both the same: every hypothesis goes to the script tracker, and an empty final marks the start of a
/// session and each segment's end.
///
/// It reads the camera plugin's own microphone capture (the one a take records) instead of opening the
/// microphone, so there is a single capture and nothing is lost while a session restarts: audio that
/// arrives between sessions is kept for about half a second and handed to the next one.
/// Everything runs on the main thread.
final class SpeechRecognizerChannel: NSObject, FlutterStreamHandler {
    private weak var camera: EchoprompterCameraPlugin?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var sink: FlutterEventSink?

    private var bias: [String] = []
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0 // bumped whenever a session ends; callbacks of older ones are ignored
    private var running = false
    private var failures = 0 // consecutive service failures; five give up
    private var lastError = ""
    private var restartTimes: [TimeInterval] = []
    private var idleTimer: Timer?
    private var lengthTimer: Timer?
    private var restartTimer: Timer?

    // Audio that arrives while no session is open, kept for the next one.
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFrameCount = 0

    private static let segmentSilence: TimeInterval = 1.5 // no new words for this long ends a segment
    private static let maxSession: TimeInterval = 50 // Apple stops a task after about a minute
    private static let keepFrames: AVAudioFrameCount = 8000 // 0.5 s at 16 kHz
    private static let maxBias = 100
    private static let dictationMessage = "Turn on Dictation in Settings > General > Keyboard to use Voice mode."

    init(camera: EchoprompterCameraPlugin) {
        self.camera = camera
        super.init()
    }

    static func register(with registrar: FlutterPluginRegistrar, camera: EchoprompterCameraPlugin) {
        let c = SpeechRecognizerChannel(camera: camera)
        let method = FlutterMethodChannel(name: "com.echoprompter/speech", binaryMessenger: registrar.messenger())
        method.setMethodCallHandler { call, result in c.handle(call, result: result) }
        FlutterEventChannel(name: "com.echoprompter/speech/events", binaryMessenger: registrar.messenger())
            .setStreamHandler(c)
        camera.speech = c
    }

    // MARK: Channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable": available(result)
        case "setBias":
            bias = Array(((call.arguments as? [String]) ?? []).prefix(Self.maxBias))
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    /// True once the reader has allowed speech recognition and English is supported; asks the first time.
    private func available(_ result: @escaping FlutterResult) {
        guard let recognizer = recognizer else { return result(false) }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { result(status == .authorized && recognizer.isAvailable) }
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        guard let recognizer = recognizer, SFSpeechRecognizer.authorizationStatus() == .authorized else {
            fail("unavailable", "Speech recognition is unavailable on this device")
            return nil
        }
        guard recognizer.isAvailable else {
            fail("language", "Speech recognition can't recognise English right now")
            return nil
        }
        running = true
        failures = 0
        restartTimes = []
        camera?.setSpeechActive(true)
        startSession()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        stop()
        sink = nil
        return nil
    }

    // MARK: Sessions

    private func startSession() {
        guard running, let recognizer = recognizer else { return }
        endSession()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if #available(iOS 16, *) { req.addsPunctuation = false }
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        if !bias.isEmpty { req.contextualStrings = bias }
        request = req
        let id = generation
        // An empty final at the start of a session, so the tracker re-anchors.
        emit("", final: true)
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.onResult(id, result, error) }
        }
        for b in pending { req.append(b) }
        pending = []
        pendingFrames = 0
        lengthTimer = Timer.scheduledTimer(withTimeInterval: Self.maxSession, repeats: false) { [weak self] _ in
            self?.finishSegment(id)
        }
    }

    /// Stops the current session without reporting anything more from it.
    private func endSession() {
        generation += 1
        idleTimer?.invalidate(); idleTimer = nil
        lengthTimer?.invalidate(); lengthTimer = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
    }

    /// Asks the recogniser to finish what it has heard; its final result then restarts the session.
    private func finishSegment(_ id: Int) {
        guard id == generation else { return }
        idleTimer?.invalidate(); idleTimer = nil
        // Audio from here on waits for the next session.
        request?.endAudio(); request = nil
    }

    private func onResult(_ id: Int, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        guard id == generation, running else { return }
        if let result = result {
            failures = 0
            let text = result.bestTranscription.formattedString
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                emit(text, final: result.isFinal)
                idleTimer?.invalidate()
                if !result.isFinal {
                    idleTimer = Timer.scheduledTimer(withTimeInterval: Self.segmentSilence, repeats: false) { [weak self] _ in
                        self?.finishSegment(id)
                    }
                }
            }
            if result.isFinal { scheduleRestart(after: 0.1) }
            return
        }
        guard let error = error as NSError? else { return }
        // "No speech detected" (1110) and "retry" (203) just mean a quiet stretch.
        let quiet = error.domain == "kAFAssistantErrorDomain" && (error.code == 1110 || error.code == 203)
        // Apple's recogniser refuses to work while Dictation is turned off; retrying can't help.
        let dictationOff = error.localizedDescription.localizedCaseInsensitiveContains("dictation")
            || (error.domain == "kLSRErrorDomain" && error.code == 201)
            || (error.domain == "kAFAssistantErrorDomain" && error.code == 1101)
        if dictationOff {
            fail("unavailable", Self.dictationMessage)
            stop()
            return
        }
        if !quiet {
            failures += 1
            lastError = "\(error.domain) \(error.code)"
            if failures >= 5 {
                fail("unavailable", "Speech recognition is not responding (\(lastError))")
                stop()
                return
            }
        }
        scheduleRestart(after: quiet ? 0.15 : 0.4)
    }

    /// Restarts after [delay]; six restarts within 1.5 s back off for 2 s.
    private func scheduleRestart(after delay: TimeInterval) {
        endSession()
        let now = Date().timeIntervalSince1970
        restartTimes = restartTimes.filter { now - $0 < 1.5 } + [now]
        let wait = restartTimes.count >= 6 ? 2.0 : delay
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            self?.startSession()
        }
    }

    private func stop() {
        running = false
        restartTimer?.invalidate(); restartTimer = nil
        endSession()
        pending = []
        pendingFrames = 0
        camera?.setSpeechActive(false)
    }

    // MARK: Audio and events

    /// 16 kHz mono float from the camera plugin's capture.
    func feed(_ buffer: AVAudioPCMBuffer) {
        DispatchQueue.main.async {
            guard self.running else { return }
            if let req = self.request {
                req.append(buffer)
                return
            }
            self.pending.append(buffer)
            self.pendingFrames += buffer.frameLength
            while self.pendingFrames > Self.keepFrames, let first = self.pending.first {
                self.pendingFrames -= first.frameLength
                self.pending.removeFirst()
            }
        }
    }

    private func emit(_ text: String, final: Bool) {
        sink?(["text": text, "final": final])
    }

    private func fail(_ code: String, _ message: String) {
        sink?(FlutterError(code: code, message: message, details: nil))
    }
}
