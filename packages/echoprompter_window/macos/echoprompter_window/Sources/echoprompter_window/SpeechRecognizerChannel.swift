import AVFoundation
import CoreAudio
import FlutterMacOS
import Speech

/// Voice and Audio mode's recogniser on macOS: Apple's `SFSpeechRecognizer`, on-device where the Mac
/// supports it for English (otherwise Apple's servers), streaming partial hypotheses to Dart while the event
/// stream is listened to. It is the counterpart of the iOS and Android recognisers, so Dart treats all of
/// them the same: every hypothesis goes to the script tracker, and an empty final marks the start of a
/// session and each segment's end.
///
/// It captures the microphone itself (an `AVCaptureSession`, like iOS). Voice mode listens through a connected USB or Bluetooth headset
/// microphone and otherwise the system's input; Audio mode must hear the speaker, so it uses the built-in
/// microphone. Audio that arrives while a session restarts is kept for about half a second and handed to
/// the next one. Everything but the capture callback runs on the main thread.
final class SpeechRecognizerChannel: NSObject, FlutterStreamHandler, AVCaptureAudioDataOutputSampleBufferDelegate {
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

    // Microphone capture.
    private var session: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "echoprompter.speech.capture")
    private var converter: AVAudioConverter? // used on the capture queue only
    private var converterSource: AVAudioFormat?
    private var headsetMic = true
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var buffersSeen = 0 // buffers delivered by the current capture
    private var captureAttempts = 0 // reopenings in a row without audio; reset once audio flows

    private static let segmentSilence: TimeInterval = 1.5 // no new words for this long ends a segment
    private static let maxSession: TimeInterval = 50 // Apple stops a task after about a minute
    private static let keepFrames: AVAudioFrameCount = 8000 // 0.5 s at 16 kHz
    private static let maxBias = 100
    private static let dictationMessage = "Turn on Dictation in System Settings > Keyboard to use Voice mode."

    static func register(with registrar: FlutterPluginRegistrar) {
        let c = SpeechRecognizerChannel()
        let method = FlutterMethodChannel(name: "com.echoprompter/speech", binaryMessenger: registrar.messenger)
        method.setMethodCallHandler { call, result in c.handle(call, result: result) }
        FlutterEventChannel(name: "com.echoprompter/speech/events", binaryMessenger: registrar.messenger)
            .setStreamHandler(c)
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
        guard let recognizer = recognizer, Self.hasUsageDescriptions else { return result(false) }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined && Self.launchedFromTerminal {
            NSLog("EchoPrompter: speech permission can't be asked for when the app is started by a terminal or IDE (flutter run): "
                + "macOS checks that program's Info.plist instead of ours and ends the app. Start it with `open EchoPrompter.app` once to grant it.")
            return result(false)
        }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { result(status == .authorized && recognizer.isAvailable) }
        }
    }

    /// Started by a program other than launchd (`flutter run`, a debugger): macOS then holds that program
    /// responsible for the app's privacy requests and checks its Info.plist, not ours.
    private static var launchedFromTerminal: Bool { getppid() != 1 }

    /// macOS ends the app, instead of failing the request, when a privacy prompt has no usage text in the bundle.
    private static var hasUsageDescriptions: Bool {
        ["NSSpeechRecognitionUsageDescription", "NSMicrophoneUsageDescription"]
            .allSatisfy { Bundle.main.object(forInfoDictionaryKey: $0) != nil }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        guard Self.hasUsageDescriptions else {
            fail("unavailable", "This build is missing its speech recognition permission text. Rebuild the app.")
            return nil
        }
        headsetMic = (arguments as? [String: Any])?["headset"] as? Bool ?? true
        guard let recognizer = recognizer, SFSpeechRecognizer.authorizationStatus() == .authorized else {
            fail("unavailable", "Speech recognition is unavailable on this Mac")
            return nil
        }
        guard recognizer.isAvailable else {
            fail("language", "Speech recognition can't recognise English right now")
            return nil
        }
        running = true
        failures = 0
        restartTimes = []
        captureAttempts = 0
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard self.running else { return }
                guard granted, self.startCapture() else {
                    self.stop()
                    self.fail("unavailable", "Microphone access is needed for Voice control")
                    return
                }
                self.startSession()
            }
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        stop()
        sink = nil
        return nil
    }

    // MARK: Microphone

    /// Opens the microphone; false if it can't be opened.
    ///
    /// It is an `AVCaptureSession` on one chosen device, as on iOS, not an `AVAudioEngine`: the engine ties
    /// the input to the system's output device and kept reconfiguring itself, or stayed silent, whenever a USB
    /// headset was the input. A watchdog opens the microphone again if no audio shows up.
    private func startCapture() -> Bool {
        stopCapture()
        buffersSeen = 0
        guard let device = Self.captureDevice(headset: headsetMic),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let s = AVCaptureSession()
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: captureQueue)
        guard s.canAddInput(input), s.canAddOutput(out) else { return false }
        s.addInput(input)
        s.addOutput(out)
        session = s
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: s, queue: .main) { [weak self] _ in
                self?.recoverCapture()
            },
            // The device was unplugged.
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: device, queue: .main) { [weak self] _ in
                self?.recoverCapture()
            },
        ]
        captureQueue.async { s.startRunning() }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self = self, self.running, self.session === s else { return }
            if self.buffersSeen == 0 { self.recoverCapture() }
        }
        return true
    }

    /// Opens the microphone again after it stopped or stayed silent; gives up after a few tries in a row.
    private func recoverCapture() {
        guard running else { return }
        captureAttempts += 1
        if captureAttempts > 5 {
            stop()
            fail("unavailable", "The microphone isn't delivering audio. Check the input in System Settings > Sound.")
            return
        }
        stopCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.running else { return }
            if !self.startCapture() { self.recoverCapture() }
        }
    }

    private func stopCapture() {
        watchdog?.invalidate(); watchdog = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let s = session { captureQueue.async { s.stopRunning() } }
        session = nil
    }

    /// Voice mode: a connected USB device, else a Bluetooth one, else the system input, as the Android and iOS capture
    /// does. Audio mode: the built-in microphone, which can hear the speaker.
    private static func captureDevice(headset: Bool) -> AVCaptureDevice? {
        let devices = inputDevices()
        let wanted: AudioDeviceID?
        if headset {
            let order: [UInt32] = [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
            wanted = order.lazy.compactMap { t in devices.first { $0.transport == t }?.id }.first
        } else {
            wanted = devices.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }?.id
        }
        if let id = wanted, let uid = deviceUID(id), let d = AVCaptureDevice(uniqueID: uid) { return d }
        return AVCaptureDevice.default(for: .audio)
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }

    private static func inputDevices() -> [(id: AudioDeviceID, transport: UInt32)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0 else { return nil }
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            var tAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &tAddress, 0, nil, &tSize, &transport) == noErr else { return nil }
            return (id, transport)
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Microphone audio as 16 kHz mono float (on the capture queue).
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        var d = asbd.pointee
        guard let srcFmt = AVAudioFormat(streamDescription: &d),
              let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return }
        if converter == nil || converterSource != srcFmt {
            converter = AVAudioConverter(from: srcFmt, to: dstFmt)
            converterSource = srcFmt
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList) == noErr else { return }
        let outCap = AVAudioFrameCount(Double(frames) * 16000 / srcFmt.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCap) else { return }
        var supplied = false
        var err: NSError?
        converter?.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return inBuf
        }
        if err == nil, out.frameLength > 0 { feed(out) }
    }

    // MARK: Sessions

    private func startSession() {
        guard running, let recognizer = recognizer else { return }
        endSession()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if #available(macOS 13, *) { req.addsPunctuation = false }
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
        stopCapture()
        pending = []
        pendingFrames = 0
    }

    // MARK: Audio and events

    /// 16 kHz mono float from the microphone capture (called on the audio thread).
    private func feed(_ buffer: AVAudioPCMBuffer) {
        DispatchQueue.main.async {
            guard self.running else { return }
            self.buffersSeen += 1
            self.captureAttempts = 0
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
