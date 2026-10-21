import AVFoundation
import Flutter
import Photos
import UIKit

/// AVCaptureSession preview into a Flutter texture, plus an AVAssetWriter
/// recorder. The same audio sample buffers feed the file and the speech
/// engine (16 kHz mono float), so Voice mode works while recording.
public class EchopromptCameraPlugin: NSObject, FlutterPlugin, FlutterTexture, FlutterStreamHandler,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
{
    private let textures: FlutterTextureRegistry
    private var textureId: Int64 = -1
    private let queue = DispatchQueue(label: "echoprompt.camera")
    private var session: AVCaptureSession?
    private var videoOut: AVCaptureVideoDataOutput?
    private var audioOut: AVCaptureAudioDataOutput?
    private var latest: CVPixelBuffer?
    private let latestLock = NSLock()
    private var front = true
    private var orientationLocked = false
    private var lockedAngle: CGFloat = 90

    private var audioSink: FlutterEventSink?
    private var eventSink: FlutterEventSink?
    private var audioListening = false

    // Writer state (touched on `queue` only).
    private var writer: AVAssetWriter?
    private var vInput: AVAssetWriterInput?
    private var aInput: AVAssetWriterInput?
    private var writerStarted = false
    private var startTime: CMTime = .invalid
    private var lastTime: CMTime = .zero
    // Pause support: samples are dropped while paused and later ones are
    // shifted back by `pausedOffset` so the file has no gap.
    private var paused = false
    private var resuming = false
    private var pausedOffset: CMTime = .zero
    private var lastRawVideo: CMTime = .zero
    private var outputURL: URL?
    private var landscapeRecording = false
    private var recordingHeight = 1080
    private var useHEVC = false

    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    init(textures: FlutterTextureRegistry) { self.textures = textures }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let p = EchopromptCameraPlugin(textures: registrar.textures())
        let ch = FlutterMethodChannel(name: "com.echoprompt/camera", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(p, channel: ch)
        FlutterEventChannel(name: "com.echoprompt/camera/audio", binaryMessenger: registrar.messenger())
            .setStreamHandler(AudioHandler(p))
        FlutterEventChannel(name: "com.echoprompt/camera/events", binaryMessenger: registrar.messenger())
            .setStreamHandler(p)
        NotificationCenter.default.addObserver(p, selector: #selector(interrupted), name: .AVCaptureSessionWasInterrupted, object: nil)
        NotificationCenter.default.addObserver(p, selector: #selector(interrupted), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(p, selector: #selector(deviceRotated), name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    // Events stream
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { eventSink = events; return nil }
    public func onCancel(withArguments arguments: Any?) -> FlutterError? { eventSink = nil; return nil }

    // Audio stream: starts the mic only while a Dart listener exists.
    private final class AudioHandler: NSObject, FlutterStreamHandler {
        let p: EchopromptCameraPlugin
        init(_ p: EchopromptCameraPlugin) { self.p = p }
        func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            self.p.audioSink = events; self.p.audioListening = true; self.p.queue.async { self.p.updateAudioInput() }; return nil
        }
        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            self.p.audioSink = nil; self.p.audioListening = false; self.p.queue.async { self.p.updateAudioInput() }; return nil
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let a = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "startPreview": startPreview(front: (a["facing"] as? String) == "front", result: result)
        case "stopPreview": stopPreview(); result(nil)
        case "startRecording":
            landscapeRecording = a["landscape"] as? Bool ?? false
            recordingHeight = a["height"] as? Int ?? 1080
            useHEVC = a["hevc"] as? Bool ?? false
            queue.async { do { try self.beginWriter(); DispatchQueue.main.async { result(nil) } }
                catch { DispatchQueue.main.async { result(FlutterError(code: "record", message: "\(error)", details: nil)) } } }
        case "pauseRecording": queue.async { if self.writer != nil { self.paused = true; self.resuming = false }; DispatchQueue.main.async { result(nil) } }
        case "resumeRecording": queue.async { if self.paused { self.paused = false; self.resuming = true }; DispatchQueue.main.async { result(nil) } }
        case "stopRecording": finishRecording(reason: a["reason"] as? String ?? "user", result: result)
        case "saveToGallery": saveToGallery(a["path"] as? String ?? "", result: result)
        case "headphonesConnected":
            let outs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
            result(outs.contains { [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio].contains($0) })
        case "setReferenceRoute": result(nil) // input always built-in mic; see configureAudioSession
        default: result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Preview

    private func startPreview(front: Bool, result: @escaping FlutterResult) {
        stopPreview()
        self.front = front
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { DispatchQueue.main.async { result(FlutterError(code: "permission", message: "Camera access denied", details: nil)) }; return }
            self.queue.async {
                let s = AVCaptureSession()
                s.beginConfiguration()
                s.sessionPreset = .hd1920x1080
                guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
                      let input = try? AVCaptureDeviceInput(device: dev), s.canAddInput(input) else {
                    DispatchQueue.main.async { result(FlutterError(code: "camera", message: "No camera", details: nil)) }
                    return
                }
                s.addInput(input)
                let v = AVCaptureVideoDataOutput()
                v.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                v.alwaysDiscardsLateVideoFrames = true
                v.setSampleBufferDelegate(self, queue: self.queue)
                if s.canAddOutput(v) { s.addOutput(v) }
                self.videoOut = v
                s.commitConfiguration()
                self.session = s
                self.updateVideoRotation()
                s.startRunning()
                DispatchQueue.main.async {
                    self.textureId = self.textures.register(self)
                    let landscape = self.currentAngle() == 0 || self.currentAngle() == 180
                    result(["textureId": self.textureId, "width": landscape ? 1920 : 1080,
                            "height": landscape ? 1080 : 1920, "mirrored": front, "quarterTurns": 0])
                }
            }
        }
    }

    private func stopPreview() {
        if writer != nil { finishRecording(reason: "user", result: { _ in }) }
        queue.sync {
            session?.stopRunning(); session = nil; videoOut = nil; audioOut = nil
            latestLock.lock(); latest = nil; latestLock.unlock()
        }
        if textureId >= 0 { textures.unregisterTexture(textureId); textureId = -1 }
    }

    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        latestLock.lock(); defer { latestLock.unlock() }
        guard let b = latest else { return nil }
        return Unmanaged.passRetained(b)
    }

    // MARK: Orientation (locked while recording so the file has one orientation)

    private func currentAngle() -> CGFloat {
        if orientationLocked { return lockedAngle }
        switch UIDevice.current.orientation {
        case .landscapeLeft: return 0     // home button on the right
        case .landscapeRight: return 180
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    @objc private func deviceRotated() { queue.async { self.updateVideoRotation() } }

    private func updateVideoRotation() {
        guard let c = videoOut?.connection(with: .video) else { return }
        let angle = currentAngle()
        if #available(iOS 17.0, *) {
            if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
        } else if c.isVideoOrientationSupported {
            switch angle {
            case 0: c.videoOrientation = .landscapeRight
            case 180: c.videoOrientation = .landscapeLeft
            case 270: c.videoOrientation = .portraitUpsideDown
            default: c.videoOrientation = .portrait
            }
        }
    }

    // MARK: Audio capture (one stream → file + speech)

    private func updateAudioInput() {
        guard let s = session else { return }
        let need = audioListening || writer != nil
        if need && audioOut == nil {
            configureAudioSession()
            s.beginConfiguration()
            if let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic), s.canAddInput(input) {
                s.addInput(input)
                let o = AVCaptureAudioDataOutput()
                o.setSampleBufferDelegate(self, queue: queue)
                if s.canAddOutput(o) { s.addOutput(o); audioOut = o }
            }
            s.commitConfiguration()
        } else if !need, let o = audioOut {
            s.beginConfiguration()
            s.removeOutput(o)
            s.inputs.filter { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }.forEach(s.removeInput)
            s.commitConfiguration()
            audioOut = nil
        }
    }

    private func configureAudioSession() {
        let a = AVAudioSession.sharedInstance()
        // Headphone output via A2DP, input pinned to the built-in mic.
        try? a.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try? a.setActive(true)
        if let builtIn = a.availableInputs?.first(where: { $0.portType == .builtInMic }) { try? a.setPreferredInput(builtIn) }
    }

    // MARK: Sample buffers

    public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOut {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            latestLock.lock(); latest = pb; latestLock.unlock()
            if textureId >= 0 { DispatchQueue.main.async { self.textures.textureFrameAvailable(self.textureId) } }
            write(sb, video: true)
        } else if output === audioOut {
            write(sb, video: false)
            sendSpeech(sb)
        }
    }

    private func sendSpeech(_ sb: CMSampleBuffer) {
        guard audioListening, let sink = audioSink,
              let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        var d = asbd.pointee
        guard let srcFmt = AVAudioFormat(streamDescription: &d),
              let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return }
        if converter == nil || converterSource != srcFmt {
            converter = AVAudioConverter(from: srcFmt, to: dstFmt); converterSource = srcFmt
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frames) else { return }
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
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
        let data = Data(bytes: ch, count: Int(out.frameLength) * 4)
        DispatchQueue.main.async { sink(FlutterStandardTypedData(bytes: data)) }
    }

    // MARK: Writer

    private func beginWriter() throws {
        guard writer == nil, session != nil else { throw NSError(domain: "echoprompt", code: 1, userInfo: [NSLocalizedDescriptionKey: "No preview"]) }
        orientationLocked = true
        lockedAngle = currentAngle()
        updateVideoRotation()
        updateAudioInput()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("echoprompt_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let portrait = !landscapeRecording
        let h = recordingHeight, wd = h * 16 / 9
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: useHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: portrait ? h : wd, AVVideoHeightKey: portrait ? wd : h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
        ])
        v.expectsMediaDataInRealTime = true
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ])
        a.expectsMediaDataInRealTime = true
        w.add(v); w.add(a)
        writer = w; vInput = v; aInput = a; outputURL = url
        writerStarted = false; startTime = .invalid; lastTime = .zero
        paused = false; resuming = false; pausedOffset = .zero; lastRawVideo = .zero
        w.startWriting()
    }

    private func write(_ sb: CMSampleBuffer, video: Bool) {
        guard let w = writer, w.status == .writing, !paused else { return }
        var pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !writerStarted {
            // Start the file on the first video frame so audio and video align.
            guard video else { return }
            w.startSession(atSourceTime: pts); startTime = pts; writerStarted = true
        }
        if resuming {
            // Resync on the first video frame after a pause; audio waits for it.
            guard video else { return }
            let gap = CMTimeSubtract(pts, lastRawVideo)
            pausedOffset = CMTimeAdd(pausedOffset, CMTimeSubtract(gap, CMTime(value: 1, timescale: 30)))
            resuming = false
        }
        let input = video ? vInput : aInput
        if input?.isReadyForMoreMediaData == true {
            var out = sb
            if pausedOffset != .zero {
                var timing = CMSampleTimingInfo(
                    duration: CMSampleBufferGetDuration(sb),
                    presentationTimeStamp: CMTimeSubtract(pts, pausedOffset),
                    decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                                            sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                      let c = copy else { return }
                out = c
            }
            input?.append(out)
            if video { lastRawVideo = pts; pts = CMTimeSubtract(pts, pausedOffset); lastTime = pts }
        }
    }

    private func finishRecording(reason: String, result: @escaping FlutterResult) {
        queue.async {
            guard let w = self.writer, let url = self.outputURL else {
                DispatchQueue.main.async { result(FlutterError(code: "record", message: "Not recording", details: nil)) }; return
            }
            let duration = self.writerStarted ? CMTimeGetSeconds(CMTimeSubtract(self.lastTime, self.startTime)) : 0
            self.vInput?.markAsFinished(); self.aInput?.markAsFinished()
            self.writer = nil; self.vInput = nil; self.aInput = nil
            self.orientationLocked = false
            self.updateVideoRotation()
            self.updateAudioInput()
            w.finishWriting {
                if reason != "user" { DispatchQueue.main.async { self.eventSink?(["type": reason, "path": url.path]) } }
                DispatchQueue.main.async {
                    result(["path": url.path, "durationMs": Int(duration * 1000), "reason": reason])
                }
            }
        }
    }

    @objc private func interrupted() {
        if writer != nil { finishRecording(reason: "interrupted", result: { _ in }) }
    }

    private func saveToGallery(_ path: String, result: @escaping FlutterResult) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { result(FlutterError(code: "permission", message: "Photos access denied", details: nil)) }; return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: URL(fileURLWithPath: path))
            }) { ok, err in
                DispatchQueue.main.async { ok ? result(nil) : result(FlutterError(code: "save", message: err?.localizedDescription, details: nil)) }
            }
        }
    }
}
