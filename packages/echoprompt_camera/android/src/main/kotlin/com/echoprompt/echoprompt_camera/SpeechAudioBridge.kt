package com.echoprompt.echoprompt_camera

import android.os.ParcelFileDescriptor

/**
 * Lets the app's speech recogniser listen to this plugin's microphone capture, so Voice mode and a
 * take's audio use one capture. Everything here is called on the main thread except [level], which
 * the capture thread writes.
 */
object SpeechAudioBridge {
    /** RMS of the latest microphone buffer, 0..1. */
    @Volatile var level = 0f

    internal var opener: (() -> ParcelFileDescriptor?)? = null
    internal var closer: (() -> Unit)? = null

    /**
     * Read end of a pipe carrying the microphone (16 kHz, mono, 16-bit PCM); the capture starts if it
     * isn't running. Null if the microphone can't be opened. The pipe stays open until [closePipe].
     */
    fun openPipe(): ParcelFileDescriptor? = opener?.invoke()

    fun closePipe() {
        closer?.invoke()
    }
}
