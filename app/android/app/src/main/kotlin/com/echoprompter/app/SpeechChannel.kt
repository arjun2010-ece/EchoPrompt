package com.echoprompter.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import com.echoprompter.echoprompter_camera.SpeechAudioBridge
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Voice mode's recogniser on Android: the on-device [SpeechRecognizer] where the phone has one
 * (API 31+), else, or when it keeps failing, the system recogniser (which may use the network),
 * streaming partial hypotheses to Dart while the event stream is listened to.
 *
 * Everything follows the reference app's engine (`ud` / `sd` / `qd` in the decompile): every
 * callback is tied to the session that started it, sessions restart as they end, three watchdogs
 * recover a stalled service, restarts are rate limited, and on Android 13+ the recogniser reads our
 * own microphone capture (the one a take records) instead of opening the microphone itself.
 * Everything runs on the main thread.
 */
class SpeechChannel(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var recognizer: SpeechRecognizer? = null
    private var bias = arrayListOf<String>()
    private var listener: SessionListener? = null

    private var running = false // engine started and not stopped
    private var sessionLive = false // the current session may still deliver callbacks
    private var generation = 0L // bumped whenever a session ends; callbacks of older ones are ignored
    private var sessionNo = 0
    private var sessionStartedAt = 0L
    private var restartBurst = 0
    private var lastRestartAt = 0L
    private var failures = 0 // consecutive service failures; five give up
    private var errorStreak = 0
    private var sharedErrorStreak = 0
    private var sharedWorked = false // the shared audio has produced a transcript
    private var sharedBackoffMs = 1000L
    private var gaveUp = false
    private var onDeviceAllowed = true // cleared once the on-device recogniser has failed: system one from then on
    private var onDevice = false // the current recogniser is the on-device one
    private var silenceTuning = true // silence lengths + segmented session; dropped if the service rejects them
    private var sharedAudio: ParcelFileDescriptor? = null // our microphone capture, owned by the camera plugin
    private var micFallback = true // the listener allows the recogniser's own microphone (reference: Prompter screen)
    private var sharedFallbackAllowed = false // may drop to the recogniser's own microphone
    private var activityStart: Long? = null
    private var activityLast: Long? = null
    private var activityMs = 0L

    private var readyWatchdog: Runnable? = null
    private var utteranceWatchdog: Runnable? = null
    private var speechWatchdog: Runnable? = null

    private val restart = Runnable { startSession() }

    /** Notices a shared audio source that is loud but never produces a transcript. */
    private val activityCheck = object : Runnable {
        override fun run() {
            if (!running || sharedAudio == null || sharedWorked) return
            val now = SystemClock.elapsedRealtime()
            val loud = SpeechAudioBridge.level >= LOUD_LEVEL
            activityLast?.let { if (now - it > 1500) resetActivity() }
            if (loud) {
                if (activityStart == null) activityStart = now
                activityLast = now
                activityMs += 250
            }
            val start = activityStart
            if (!loud || start == null || now - start < 8000 || activityMs < 1500) {
                main.postDelayed(this, 250)
                return
            }
            if (!onDevice) {
                Log.i(TAG, "Shared audio has activity; waiting for recognizable speech")
                return
            }
            sharedFailed("microphone activity produced no initial transcript")
        }
    }

    init {
        MethodChannel(messenger, "com.echoprompter/speech").setMethodCallHandler(this)
        EventChannel(messenger, "com.echoprompter/speech/events").setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(available())
            "setBias" -> {
                bias = ArrayList(call.arguments<List<String>>() ?: emptyList())
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        micFallback = (arguments as? Map<*, *>)?.get("micFallback") as? Boolean ?: true
        selectSharedAudio()
        begin()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        end()
        sharedAudio = null
        SpeechAudioBridge.closePipe()
    }

    fun dispose() {
        onCancel(null)
    }

    private fun onDeviceAvailable() =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    private fun available() = SpeechRecognizer.isRecognitionAvailable(context) || onDeviceAvailable()

    private fun createRecognizer(): SpeechRecognizer {
        onDevice = onDeviceAllowed && onDeviceAvailable()
        Log.i(
            TAG,
            "created recognizer: ${if (onDevice) "on-device" else "system"} · $LANGUAGE · " +
                if (sharedAudio != null) "shared audio" else "system microphone",
        )
        return if (onDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
    }

    /**
     * Voice mode reads our own microphone capture through a pipe on Android 13+ (reference `wd3.E`/`f`), so
     * no audio is lost while a session starts or restarts; below that the recogniser opens the microphone.
     */
    private fun selectSharedAudio() {
        sharedAudio = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) SpeechAudioBridge.openPipe() else null
        sharedFallbackAllowed = sharedAudio != null && micFallback
    }

    // --- Engine ---------------------------------------------------------------------------------

    /** Starts listening from a clean slate. */
    private fun begin() {
        end()
        running = true
        onDeviceAllowed = true
        failures = 0
        silenceTuning = true
        errorStreak = 0
        sharedErrorStreak = 0
        sharedWorked = false
        sharedBackoffMs = 1000L
        restartBurst = 0
        lastRestartAt = 0L
        resetActivity()
        gaveUp = false
        main.post { startSession() }
        if (sharedAudio != null) main.postDelayed(activityCheck, 250)
    }

    /** Stops listening and releases the recogniser. */
    private fun end() {
        running = false
        main.removeCallbacksAndMessages(null)
        discard()
    }

    /** Throws the current session and recogniser away. */
    private fun discard() {
        sessionLive = false
        generation++
        clearReady()
        clearUtterance()
        clearSpeech()
        listener?.release()
        listener = null
        val r = recognizer
        recognizer = null
        try {
            r?.destroy()
        } catch (_: Exception) {
        }
    }

    /** Ends the current session and starts the next one after [delayMs], with a back-off if they churn. */
    private fun restartIn(delayMs: Long) {
        if (!running) return
        sessionLive = false
        generation++
        clearReady()
        clearUtterance()
        clearSpeech()
        val now = SystemClock.elapsedRealtime()
        if (now - lastRestartAt < 1500) {
            restartBurst++
            if (restartBurst >= 6) {
                restartBurst = 0
                discard()
                main.removeCallbacks(restart)
                main.postDelayed(restart, 2000)
                return
            }
        } else {
            restartBurst = 0
        }
        lastRestartAt = now
        main.removeCallbacks(restart)
        main.postDelayed(restart, delayMs)
    }

    private fun startSession() {
        if (!running) return
        if (!available()) {
            giveUp("unavailable", "Speech recognition is unavailable on this device")
            return
        }
        if (sharedAudio != null && recognizer != null) discard()
        // A new session starts a new utterance: the tracker re-anchors.
        emit("", true)
        sessionNo++
        sessionStartedAt = SystemClock.elapsedRealtime()
        generation++
        val gen = generation
        sessionLive = true
        Log.i(TAG, "▶ startListening session #$sessionNo")
        try {
            val r = recognizer ?: createRecognizer().also { recognizer = it }
            val intent = buildIntent()
            var dup: ParcelFileDescriptor? = null
            val shared = sharedAudio
            if (shared != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                dup = ParcelFileDescriptor.dup(shared.fileDescriptor)
                intent.putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, dup)
            }
            val l = SessionListener(gen, dup)
            listener = l
            r.setRecognitionListener(l)
            clearReady()
            readyWatchdog = Runnable { recover(gen, "service did not become ready", true) }
            main.postDelayed(readyWatchdog!!, 10000)
            r.startListening(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Could not start recognition session", e)
            if (countFailure()) return
            when {
                sharedAudio != null -> sharedFailed("session could not start")
                onDevice -> switchToSystem("on-device session could not start", false)
                else -> {
                    discard()
                    restartIn(1000)
                }
            }
        }
    }

    private fun buildIntent(withShared: Boolean = true): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, LANGUAGE)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            putExtra(RecognizerIntent.EXTRA_REQUEST_WORD_TIMING, true)
        }
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        if (onDevice) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (withShared && sharedAudio != null) {
                // The audio source itself is added by the caller (a duplicate of the pipe).
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                // 16 kHz, not the reference's 48 kHz: the on-device engine's own rate, so it doesn't rebuild
                // itself (~0.8 s deaf on the emulator) at every session start.
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
                putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
            } else if (silenceTuning) {
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MS)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MS)
                // The value names what ends a segment (here, the silence length above), not a boolean.
                putExtra(
                    RecognizerIntent.EXTRA_SEGMENTED_SESSION,
                    RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                )
            }
            val words = ArrayList(LinkedHashSet(bias))
            if (words.isNotEmpty()) putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, words)
        } else if (silenceTuning) {
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MS)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MS)
        }
    }

    // --- Recovery -------------------------------------------------------------------------------

    private fun isCurrent(gen: Long) = running && sessionLive && generation == gen

    /** A watchdog fired for session [gen]. */
    private fun recover(gen: Long, reason: String, countsAsFailure: Boolean) {
        if (!isCurrent(gen)) return
        Log.w(TAG, "Recovering recognition: $reason")
        if (countsAsFailure && countFailure()) return
        if (onDevice) {
            switchToSystem(reason, false)
            return
        }
        silenceTuning = false
        discard()
        restartIn(400)
    }

    /**
     * Five failures in a row give up. The reference swaps to the system recogniser at the points
     * that call this; here the on-device one is recreated instead.
     */
    private fun countFailure(): Boolean {
        failures++
        if (failures < 5) return false
        if (sharedAudio == null || !sharedWorked) {
            giveUp("stalled", "Speech recognition is not responding. Please try again in a moment.")
        } else {
            sharedFailed("repeated service failures after successful shared recognition")
        }
        return true
    }

    /**
     * The on-device recogniser can't handle this (reference `x`): ask for its language pack when that is
     * what's missing, then use the system recogniser, which may send audio to the network.
     */
    private fun switchToSystem(reason: String, downloadPack: Boolean) {
        Log.w(TAG, "on-device recognizer can't handle $LANGUAGE ($reason) → falling back to system recognizer")
        if (downloadPack) downloadModel()
        onDeviceAllowed = false
        resetActivity()
        errorStreak = 0
        failures = 0
        discard()
        restartIn(200)
    }

    /** The recording's audio did not work with the recogniser. */
    private fun sharedFailed(reason: String) {
        main.removeCallbacks(activityCheck)
        if (onDevice) {
            sharedErrorStreak = 0
            resetActivity()
            switchToSystem(reason, false)
            main.postDelayed(activityCheck, 250)
            return
        }
        if (sharedWorked) {
            val delay = sharedBackoffMs
            sharedBackoffMs = minOf(delay * 2, 8000L)
            Log.w(TAG, "Retrying previously working shared recognition in ${delay}ms: $reason")
            sharedErrorStreak = 0
            errorStreak = 0
            failures = 0
            discard()
            restartIn(delay)
            return
        }
        if (!sharedFallbackAllowed) {
            giveUp("shared", "This speech service cannot recognize recording audio.")
            return
        }
        if (sharedAudio == null) return
        Log.w(TAG, "shared audio failed ($reason) → falling back to recognizer-controlled mic")
        sharedAudio = null
        sharedErrorStreak = 0
        resetActivity()
        SpeechAudioBridge.closePipe()
        failures = 0
        errorStreak = 0
        discard()
        restartIn(200)
    }

    private fun giveUp(code: String, message: String) {
        if (gaveUp) return
        gaveUp = true
        sink?.error(code, message, null)
        end()
    }

    /** The offline pack is missing: ask the speech service to download it so a later session can use it. */
    private fun downloadModel() {
        val intent = buildIntent(withShared = false)
        val r = recognizer?.takeIf { onDevice } ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                r.triggerModelDownload(intent, context.mainExecutor, object : ModelDownloadListener {
                    override fun onProgress(completedPercent: Int) { Log.d(TAG, "model download for $LANGUAGE: $completedPercent%") }
                    override fun onSuccess() { Log.i(TAG, "model download completed for $LANGUAGE") }
                    override fun onScheduled() { Log.i(TAG, "model download scheduled for $LANGUAGE") }
                    override fun onError(error: Int) { Log.w(TAG, "model download failed for $LANGUAGE: error $error") }
                })
            }
        } catch (e: Exception) {
            Log.w(TAG, "model download request failed", e)
        }
    }

    private fun resetActivity() {
        activityStart = null
        activityLast = null
        activityMs = 0L
    }

    private fun clearReady() {
        readyWatchdog?.let { main.removeCallbacks(it) }
        readyWatchdog = null
    }

    private fun clearUtterance() {
        utteranceWatchdog?.let { main.removeCallbacks(it) }
        utteranceWatchdog = null
    }

    private fun clearSpeech() {
        speechWatchdog?.let { main.removeCallbacks(it) }
        speechWatchdog = null
    }

    // --- Output ---------------------------------------------------------------------------------

    private fun emit(text: String, final: Boolean) {
        sink?.success(mapOf("text" to text, "final" to final))
    }

    /** A hypothesis from the recogniser: blank ones carry nothing, a heard one proves the service works. */
    private fun hypothesis(text: String, final: Boolean) {
        if (text.isBlank()) {
            if (final) emit("", true)
            return
        }
        errorStreak = 0
        sharedErrorStreak = 0
        if (sharedAudio != null) {
            sharedWorked = true
            sharedBackoffMs = 1000L
            main.removeCallbacks(activityCheck)
            resetActivity()
        }
        failures = 0
        emit(text, final)
    }

    private fun first(results: Bundle?) =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()

    private fun sessionTime() = "%.1fs".format((SystemClock.elapsedRealtime() - sessionStartedAt) / 1000.0)

    /** The callbacks of one session; the first one to arrive also lets go of the audio pipe copy. */
    private inner class SessionListener(private val gen: Long, private var audioCopy: ParcelFileDescriptor?) :
        RecognitionListener {

        fun release() {
            audioCopy?.let {
                try {
                    it.close()
                } catch (_: Exception) {
                }
            }
            audioCopy = null
        }

        override fun onBeginningOfSpeech() {
            release()
            if (!isCurrent(gen)) return
            clearReady()
            clearUtterance()
            if (speechWatchdog == null && sharedAudio == null) {
                clearSpeech()
                speechWatchdog = Runnable { recover(gen, "speech detected but no recognition result arrived", true) }
                main.postDelayed(speechWatchdog!!, 10000)
            }
            Log.d(TAG, "onBeginningOfSpeech (session #$sessionNo, +${sessionTime()})")
        }

        override fun onEndOfSegmentedSession() {
            release()
            if (!isCurrent(gen)) return
            Log.i(TAG, "onEndOfSegmentedSession (session #$sessionNo, +${sessionTime()}) → restart")
            failures = 0
            errorStreak = 0
            sharedErrorStreak = 0
            restartIn(100)
        }

        override fun onEndOfSpeech() {
            release()
            if (!isCurrent(gen)) return
            Log.d(TAG, "onEndOfSpeech (session #$sessionNo, +${sessionTime()})")
            clearReady()
            clearSpeech()
            clearUtterance()
            utteranceWatchdog = Runnable { recover(gen, "service never completed the utterance", false) }
            main.postDelayed(utteranceWatchdog!!, 8000)
        }

        override fun onError(error: Int) {
            release()
            onSessionError(gen, error)
        }

        override fun onPartialResults(partialResults: Bundle?) {
            release()
            if (!isCurrent(gen)) return
            clearReady()
            if (utteranceWatchdog != null) {
                clearUtterance()
                utteranceWatchdog = Runnable { recover(gen, "service never completed the utterance", false) }
                main.postDelayed(utteranceWatchdog!!, 8000)
            }
            val text = first(partialResults) ?: return
            if (text.isNotBlank() && speechWatchdog != null && sharedAudio == null) {
                clearSpeech()
                speechWatchdog = Runnable { recover(gen, "speech detected but no recognition result arrived", true) }
                main.postDelayed(speechWatchdog!!, 10000)
            }
            hypothesis(text, false)
        }

        override fun onReadyForSpeech(params: Bundle?) {
            release()
            if (!isCurrent(gen)) return
            clearReady()
            Log.d(TAG, "onReadyForSpeech (session #$sessionNo, +${sessionTime()})")
        }

        override fun onResults(results: Bundle?) {
            release()
            if (!isCurrent(gen)) return
            Log.i(TAG, "onResults (session #$sessionNo, +${sessionTime()}) → restart")
            first(results)?.let { hypothesis(it, true) }
            failures = 0
            errorStreak = 0
            sharedErrorStreak = 0
            restartIn(100)
        }

        override fun onRmsChanged(rmsdB: Float) {
            release()
            if (isCurrent(gen)) clearReady()
        }

        override fun onSegmentResults(segmentResults: Bundle) {
            release()
            if (!isCurrent(gen)) return
            clearReady()
            clearUtterance()
            clearSpeech()
            Log.i(TAG, "onSegmentResults (session #$sessionNo, +${sessionTime()}) — session continues")
            val text = first(segmentResults)
            if (text != null) hypothesis(text, true) else emit("", true)
            failures = 0
            errorStreak = 0
            sharedErrorStreak = 0
        }

        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun onSessionError(gen: Long, error: Int) {
        if (!isCurrent(gen)) return
        Log.i(TAG, "onError $error (session #$sessionNo, +${sessionTime()})")
        if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
            val granted = context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                giveUp("permission", "Microphone access is needed for Voice control")
                return
            }
            if (!onDevice) {
                giveUp("audio", "The speech service could not access audio")
                return
            }
            switchToSystem("on-device service could not access audio", false)
        }
        val quiet = error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT
        if (quiet) {
            failures = 0
            errorStreak = 0
            sharedErrorStreak = 0
        }
        if (!quiet && countFailure()) return
        val audioOrBusy = error == SpeechRecognizer.ERROR_AUDIO || error == SpeechRecognizer.ERROR_CLIENT ||
            error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY
        if (sharedAudio != null && audioOrBusy) {
            sharedErrorStreak++
            if (sharedErrorStreak >= 2) {
                sharedFailed("repeated recognizer error $error")
                return
            }
        }
        if (!quiet) errorStreak++
        if (sharedAudio == null && silenceTuning &&
            (error == SpeechRecognizer.ERROR_CLIENT ||
                (errorStreak >= 2 && (error == SpeechRecognizer.ERROR_AUDIO || error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY)))
        ) {
            silenceTuning = false
            failures = 0
            errorStreak = 0
            discard()
            restartIn(400)
            return
        }
        if (!quiet && onDevice && errorStreak >= 2) {
            switchToSystem("repeated error $error", false)
            return
        }
        when (error) {
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT, SpeechRecognizer.ERROR_NO_MATCH -> restartIn(150)
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> restartIn(400)
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> Log.e(TAG, "Missing RECORD_AUDIO permission")
            ERROR_LANGUAGE_NOT_SUPPORTED ->
                if (onDevice) switchToSystem("language not supported", false) else giveUp("language", LANGUAGE_MESSAGE)
            ERROR_LANGUAGE_UNAVAILABLE ->
                if (onDevice) switchToSystem("language model unavailable", true) else giveUp("language", LANGUAGE_MESSAGE)
            else -> {
                Log.w(TAG, "Recognition error $error → full restart")
                discard()
                restartIn(1000)
            }
        }
    }

    private companion object {
        const val TAG = "SpeechEngine"
        const val LANGUAGE = "en-US"
        const val LANGUAGE_MESSAGE = "The speech service can't recognize English on this phone"
        const val SILENCE_MS = 2000
        const val LOUD_LEVEL = 0.008f
        const val ERROR_LANGUAGE_NOT_SUPPORTED = 12
        const val ERROR_LANGUAGE_UNAVAILABLE = 13
    }
}
