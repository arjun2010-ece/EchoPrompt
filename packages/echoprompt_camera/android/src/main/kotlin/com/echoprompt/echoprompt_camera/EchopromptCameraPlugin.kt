package com.echoprompt.echoprompt_camera

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Application
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.media.*
import android.os.*
import android.provider.MediaStore
import android.view.Surface
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Camera2 preview into a Flutter texture, plus a recorder where ONE
 * AudioRecord feeds both the AAC track and the speech engine (16 kHz mono).
 */
class EchopromptCameraPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private var activity: Activity? = null
    private val main = Handler(Looper.getMainLooper())
    private var audioSink: EventChannel.EventSink? = null
    private var eventSink: EventChannel.EventSink? = null

    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var facingFront = false
    private var cameraId = ""
    private var sensorOrientation = 0
    private var previewSize = android.util.Size(1920, 1080)

    private var audio: AudioCapture? = null
    private var recorder: Recorder? = null

    // MARK: FlutterPlugin

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        textures = b.textureRegistry
        MethodChannel(b.binaryMessenger, "com.echoprompt/camera").setMethodCallHandler(this)
        EventChannel(b.binaryMessenger, "com.echoprompt/camera/audio").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(a: Any?, s: EventChannel.EventSink) { audioSink = s; ensureAudio() }
            override fun onCancel(a: Any?) { audioSink = null; if (recorder == null) { audio?.stop(); audio = null } }
        })
        EventChannel(b.binaryMessenger, "com.echoprompt/camera/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(a: Any?, s: EventChannel.EventSink) { eventSink = s }
            override fun onCancel(a: Any?) { eventSink = null }
        })
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) { teardown() }
    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        activity = b.activity
        b.activity.application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityPaused(a: Activity) { if (a == activity && recorder != null) finishRecording("interrupted") }
            override fun onActivityCreated(a: Activity, s: Bundle?) {}
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityResumed(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, s: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        })
    }
    override fun onDetachedFromActivity() { activity = null }
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) { activity = b.activity }
    override fun onDetachedFromActivityForConfigChanges() {}

    // MARK: Channel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "startPreview" -> startPreview(call.argument<String>("facing") == "front", result)
                "stopPreview" -> { stopPreview(); result.success(null) }
                "startRecording" -> {
                    startRecording(call.argument<Boolean>("landscape") ?: false, call.argument<Int>("height") ?: 1080)
                    result.success(null)
                }
                "pauseRecording" -> { recorder?.pause(); result.success(null) }
                "resumeRecording" -> { recorder?.resume(); result.success(null) }
                "stopRecording" -> result.success(finishRecording(call.argument<String>("reason") ?: "user"))
                "saveToGallery" -> { saveToGallery(call.argument<String>("path")!!); result.success(null) }
                "headphonesConnected" -> result.success(headphones())
                "setReferenceRoute" -> result.success(null) // input is always the built-in mic
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("camera", e.message, null)
        }
    }

    private fun headphones(): Boolean {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
            it.type in listOf(
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_USB_HEADSET,
            )
        }
    }

    // MARK: Preview

    private fun displayRotationDegrees(): Int {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        @Suppress("DEPRECATION")
        return when (wm.defaultDisplay.rotation) {
            Surface.ROTATION_90 -> 90; Surface.ROTATION_180 -> 180; Surface.ROTATION_270 -> 270; else -> 0
        }
    }

    /** Degrees the sensor image must be rotated clockwise to appear upright. */
    private fun upright(display: Int) =
        if (facingFront) (sensorOrientation + display) % 360 else (sensorOrientation - display + 360) % 360

    @SuppressLint("MissingPermission")
    private fun startPreview(front: Boolean, result: MethodChannel.Result) {
        stopPreview()
        facingFront = front
        val mgr = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val want = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        cameraId = mgr.cameraIdList.firstOrNull { mgr.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == want }
            ?: throw IllegalStateException("No ${if (front) "front" else "back"} camera")
        val ch = mgr.getCameraCharacteristics(cameraId)
        sensorOrientation = ch.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        val map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
        previewSize = map.getOutputSizes(SurfaceTexture::class.java)
            .filter { it.width * 9 == it.height * 16 && it.height <= 1080 }
            .maxByOrNull { it.width } ?: map.getOutputSizes(SurfaceTexture::class.java).first()

        val thread = HandlerThread("echoprompt-camera").also { it.start() }
        cameraThread = thread
        cameraHandler = Handler(thread.looper)
        val e = textures.createSurfaceTexture().also { entry = it }
        e.surfaceTexture().setDefaultBufferSize(previewSize.width, previewSize.height)

        var replied = false
        mgr.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                camera = device
                createSession(listOf(Surface(e.surfaceTexture())))
                val display = displayRotationDegrees()
                val swap = (upright(display) / 90) % 2 == 1
                // Flutter's texture layer already applies the sensor rotation, so
                // Dart only compensates for the display rotation.
                val turns = (360 - display) % 360 / 90
                if (!replied) {
                    replied = true
                    main.post {
                        result.success(mapOf(
                            "textureId" to e.id(),
                            "width" to if (swap) previewSize.height else previewSize.width,
                            "height" to if (swap) previewSize.width else previewSize.height,
                            "mirrored" to facingFront,
                            "quarterTurns" to turns,
                        ))
                    }
                }
            }
            override fun onDisconnected(d: CameraDevice) { d.close(); if (recorder != null) finishRecording("interrupted") }
            override fun onError(d: CameraDevice, err: Int) {
                d.close()
                if (!replied) { replied = true; main.post { result.error("camera", "Camera error $err", null) } }
            }
        }, cameraHandler)
    }

    private fun createSession(extra: List<Surface>, record: Boolean = false) {
        val device = camera ?: return
        session?.close()
        val surfaces = extra
        val builder = device.createCaptureRequest(if (record) CameraDevice.TEMPLATE_RECORD else CameraDevice.TEMPLATE_PREVIEW)
        surfaces.forEach { builder.addTarget(it) }
        builder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
        builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
        device.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(s: CameraCaptureSession) {
                session = s
                s.setRepeatingRequest(builder.build(), null, cameraHandler)
            }
            override fun onConfigureFailed(s: CameraCaptureSession) { emit(mapOf("type" to "error", "message" to "session")) }
        }, cameraHandler)
    }

    private fun stopPreview() {
        if (recorder != null) finishRecording("user")
        session?.close(); session = null
        camera?.close(); camera = null
        entry?.release(); entry = null
        cameraThread?.quitSafely(); cameraThread = null
    }

    // MARK: Audio (shared by file and speech)

    private fun ensureAudio() {
        if (audio == null) {
            audio = AudioCapture { pcm48k, ptsUs ->
                recorder?.onAudio(pcm48k, ptsUs)
                val sink = audioSink
                if (sink != null) {
                    val out = downsampleTo16kFloat(pcm48k)
                    main.post { sink.success(out) }
                }
            }.also { it.start(context) }
        }
    }

    private fun downsampleTo16kFloat(pcm: ShortArray): ByteArray {
        val n = pcm.size / 3
        val bb = ByteBuffer.allocate(n * 4).order(ByteOrder.nativeOrder())
        for (i in 0 until n) {
            val avg = (pcm[i * 3] + pcm[i * 3 + 1] + pcm[i * 3 + 2]) / 3f
            bb.putFloat(avg / 32768f)
        }
        return bb.array()
    }

    // MARK: Recording

    @SuppressLint("MissingPermission")
    private fun startRecording(landscape: Boolean, height: Int) {
        check(recorder == null) { "Already recording" }
        val e = entry ?: error("No preview")
        ensureAudio()
        // Orientation is locked by Dart while recording, so the display rotation
        // now is the file's orientation ([landscape] is informational).
        val hint = upright(displayRotationDegrees())
        val file = File(context.cacheDir, "echoprompt_${System.currentTimeMillis()}.mp4")
        val r = Recorder(file, previewSize.width, previewSize.height, hint) { reason -> main.post { finishRecording(reason) } }
        recorder = r
        context.startForegroundService(Intent(context, RecordingService::class.java))
        createSession(listOf(Surface(e.surfaceTexture()), r.videoSurface), record = true)
        r.start()
    }

    private fun finishRecording(reason: String): Map<String, Any>? {
        val r = recorder ?: return null
        recorder = null
        val (path, durationMs) = r.stop()
        context.stopService(Intent(context, RecordingService::class.java))
        entry?.let { createSession(listOf(Surface(it.surfaceTexture()))) }
        if (audioSink == null) { audio?.stop(); audio = null }
        if (reason != "user") emit(mapOf("type" to reason, "path" to path))
        return mapOf("path" to path, "durationMs" to durationMs.toInt(), "reason" to reason)
    }

    private fun saveToGallery(path: String) {
        val src = File(path)
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, src.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            if (Build.VERSION.SDK_INT >= 29) put(MediaStore.Video.Media.RELATIVE_PATH, "DCIM/EchoPrompt")
        }
        val uri = context.contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)!!
        context.contentResolver.openOutputStream(uri)!!.use { out -> src.inputStream().use { it.copyTo(out) } }
    }

    private fun emit(m: Map<String, Any>) = main.post { eventSink?.success(m) }

    private fun teardown() {
        stopPreview(); audio?.stop(); audio = null
    }
}

/** 48 kHz mono PCM16 from the built-in microphone. */
private class AudioCapture(val onData: (ShortArray, Long) -> Unit) {
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false

    @SuppressLint("MissingPermission")
    fun start(context: Context) {
        val rate = 48000
        val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val r = AudioRecord(MediaRecorder.AudioSource.CAMCORDER, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, min * 4)
        // Keep input on the built-in mic so Bluetooth output keeps A2DP quality.
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        am.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
            ?.let { r.setPreferredDevice(it) }
        record = r
        r.startRecording()
        running = true
        thread = Thread {
            val buf = ShortArray(rate / 50) // 20 ms
            while (running) {
                val n = r.read(buf, 0, buf.size)
                if (n > 0) onData(buf.copyOf(n - n % 3), SystemClock.elapsedRealtimeNanos() / 1000)
            }
        }.also { it.start() }
    }

    fun stop() {
        running = false
        thread?.join(500)
        record?.stop(); record?.release(); record = null
    }
}

/** H.264 + AAC into an MP4. Video comes from [videoSurface]; audio is pushed. */
private class Recorder(
    val file: File, w: Int, h: Int, orientationHint: Int,
    val onFailure: (String) -> Unit,
) {
    private val videoCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val audioCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private val muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    val videoSurface: Surface
    private var videoTrack = -1
    private var audioTrack = -1
    private var muxerStarted = false
    private val lock = Object()
    private var startUs = 0L
    private var lastPtsUs = 0L
    // Paused spans in the recorder's raw clock; samples inside are dropped and
    // later ones are shifted back so the file has no gap.
    private val pauses = mutableListOf<LongArray>()
    private var vThread: Thread? = null
    @Volatile private var running = false

    init {
        val vf = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 10_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        videoCodec.configure(vf, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        videoSurface = videoCodec.createInputSurface()
        val af = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, 48000, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
        }
        audioCodec.configure(af, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        muxer.setOrientationHint(orientationHint)
    }

    fun start() {
        startUs = SystemClock.elapsedRealtimeNanos() / 1000
        videoCodec.start(); audioCodec.start()
        running = true
        vThread = Thread { drain(videoCodec, true) }.also { it.start() }
    }

    private fun nowUs() = SystemClock.elapsedRealtimeNanos() / 1000

    fun pause() {
        synchronized(pauses) {
            if (pauses.lastOrNull()?.get(1) != Long.MAX_VALUE) pauses.add(longArrayOf(nowUs(), Long.MAX_VALUE))
        }
    }

    fun resume() {
        synchronized(pauses) {
            pauses.lastOrNull()?.takeIf { it[1] == Long.MAX_VALUE }?.set(1, nowUs())
        }
    }

    /** Recording-timeline timestamp for a raw one, or -1 if it falls inside a pause. */
    private fun timeline(rawUs: Long): Long {
        synchronized(pauses) {
            var shift = 0L
            for (p in pauses) {
                if (rawUs >= p[1]) shift += p[1] - p[0] else if (rawUs >= p[0]) return -1
            }
            return (rawUs - startUs - shift).coerceAtLeast(0)
        }
    }

    fun onAudio(pcm: ShortArray, ptsUs: Long) {
        if (!running) return
        val t = timeline(ptsUs)
        if (t < 0) return
        val i = audioCodec.dequeueInputBuffer(0)
        if (i < 0) return
        val buf = audioCodec.getInputBuffer(i)!!
        buf.clear()
        buf.asShortBuffer().put(pcm)
        audioCodec.queueInputBuffer(i, 0, pcm.size * 2, t, 0)
        drainAudioOnce()
    }

    private fun drainAudioOnce() {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val idx = audioCodec.dequeueOutputBuffer(info, 0)
            when {
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> addTrack(audioCodec.outputFormat, false)
                idx >= 0 -> { write(audioCodec, idx, info, false); }
                else -> return
            }
        }
    }

    private fun addTrack(format: MediaFormat, video: Boolean) = synchronized(lock) {
        if (video) videoTrack = muxer.addTrack(format) else audioTrack = muxer.addTrack(format)
        if (videoTrack >= 0 && audioTrack >= 0 && !muxerStarted) { muxer.start(); muxerStarted = true; lock.notifyAll() }
    }

    private fun write(codec: MediaCodec, idx: Int, info: MediaCodec.BufferInfo, video: Boolean) {
        val data = codec.getOutputBuffer(idx)!!
        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
            synchronized(lock) {
                while (!muxerStarted && running) lock.wait(50)
                if (muxerStarted) {
                    // Video timestamps arrive in the camera's CLOCK_BOOTTIME base.
                    val t = if (video) timeline(info.presentationTimeUs) else info.presentationTimeUs
                    if (t >= 0) {
                        if (video) { info.presentationTimeUs = t; lastPtsUs = t }
                        muxer.writeSampleData(if (video) videoTrack else audioTrack, data, info)
                    }
                }
            }
        }
        codec.releaseOutputBuffer(idx, false)
    }

    private fun drain(codec: MediaCodec, video: Boolean) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val idx = codec.dequeueOutputBuffer(info, 10_000)
            when {
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> addTrack(codec.outputFormat, video)
                idx >= 0 -> {
                    val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    write(codec, idx, info, video)
                    if (eos) return
                }
            }
        }
    }

    /** Returns file path and duration in ms. */
    fun stop(): Pair<String, Long> {
        running = false
        try {
            videoCodec.signalEndOfInputStream()
            vThread?.join(2000)
            drainAudioOnce()
            audioCodec.stop(); videoCodec.stop()
            synchronized(lock) { if (muxerStarted) muxer.stop() }
        } catch (_: Exception) {
            onFailure("error")
        } finally {
            audioCodec.release(); videoCodec.release(); muxer.release(); videoSurface.release()
        }
        return file.path to lastPtsUs / 1000
    }
}
