package com.echoprompt.app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Voice mode's recogniser on Android: the on-device [SpeechRecognizer] (API 31+, never the
 * network one), streaming partial hypotheses to Dart while the event stream is listened to.
 * Sessions restart as they end so listening is continuous; each session is biased towards the
 * words coming up in the script. Everything runs on the main thread.
 */
class SpeechChannel(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var recognizer: SpeechRecognizer? = null
    private var listening = false
    private var bias = arrayListOf<String>()

    private val restart = Runnable { startSession() }

    /** A session that never reports ready (a recogniser stuck connecting) is retried. */
    private val watchdog = Runnable {
        recognizer?.cancel()
        startSession()
    }

    init {
        MethodChannel(messenger, "com.echoprompt/speech").setMethodCallHandler(this)
        EventChannel(messenger, "com.echoprompt/speech/events").setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(available())
            "warmUp" -> {
                if (available()) ensureRecognizer()
                result.success(null)
            }
            "setBias" -> {
                bias = ArrayList(call.arguments<List<String>>() ?: emptyList())
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        listening = true
        startSession()
    }

    override fun onCancel(arguments: Any?) {
        listening = false
        sink = null
        main.removeCallbacks(restart)
        main.removeCallbacks(watchdog)
        recognizer?.cancel()
    }

    fun dispose() {
        onCancel(null)
        recognizer?.destroy()
        recognizer = null
    }

    private fun available() =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    private fun ensureRecognizer(): SpeechRecognizer? {
        if (recognizer == null && available()) {
            recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context).also { it.setRecognitionListener(listener) }
        }
        return recognizer
    }

    private fun startSession() {
        if (!listening) return
        val r = ensureRecognizer()
        if (r == null) {
            fail("unavailable", "On-device speech recognition isn't available")
            return
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MS)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MS)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // One session keeps listening across pauses and reports each phrase as a segment.
                putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, true)
                putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, bias)
            }
        }
        main.removeCallbacks(watchdog)
        main.postDelayed(watchdog, WATCHDOG_MS)
        r.startListening(intent)
    }

    private fun scheduleRestart(delayMs: Long) {
        main.removeCallbacks(restart)
        if (listening) main.postDelayed(restart, delayMs)
    }

    private fun emit(text: String, final: Boolean) {
        sink?.success(mapOf("text" to text, "final" to final))
    }

    private fun fail(code: String, message: String) {
        listening = false
        main.removeCallbacks(restart)
        main.removeCallbacks(watchdog)
        sink?.error(code, message, null)
    }

    private fun first(results: Bundle?) =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = main.removeCallbacks(watchdog)
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle?) = emit(first(partialResults), false)

        override fun onSegmentResults(segmentResults: Bundle) = emit(first(segmentResults), true)

        override fun onEndOfSegmentedSession() = scheduleRestart(RESTART_MS)

        override fun onResults(results: Bundle?) {
            emit(first(results), true)
            scheduleRestart(RESTART_MS)
        }

        override fun onError(error: Int) {
            main.removeCallbacks(watchdog)
            when (error) {
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                    fail("permission", "Microphone access is needed for Voice control")
                ERROR_LANGUAGE_NOT_SUPPORTED, ERROR_LANGUAGE_UNAVAILABLE ->
                    fail("language", "English on-device speech recognition isn't installed")
                else -> {
                    // Nothing heard, or the recogniser dropped the session: close the utterance and go again.
                    emit("", true)
                    val busy = error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY ||
                        error == SpeechRecognizer.ERROR_TOO_MANY_REQUESTS
                    scheduleRestart(if (busy) BUSY_RESTART_MS else RESTART_MS)
                }
            }
        }
    }

    private companion object {
        const val SILENCE_MS = 2000L
        const val RESTART_MS = 250L
        const val BUSY_RESTART_MS = 2000L
        const val WATCHDOG_MS = 2000L
        const val ERROR_LANGUAGE_NOT_SUPPORTED = 12
        const val ERROR_LANGUAGE_UNAVAILABLE = 13
    }
}
