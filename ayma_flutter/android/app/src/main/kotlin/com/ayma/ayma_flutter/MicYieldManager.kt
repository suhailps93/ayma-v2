package com.ayma.ayma_flutter

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Monitors Android audio focus loss and active audio recording configurations
 * so Ayma can yield the microphone whenever another app (Gemini, News, Google
 * Assistant, Phone call, etc.) requests audio focus or starts capturing audio.
 *
 * Dispatches "onMicYielded" over the "ayma/mic_yield" MethodChannel to Dart.
 */
class MicYieldManager(
    private val context: Context,
    private val messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "ayma/mic_yield"
        private const val TAG = "MicYieldManager"
    }

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    @Volatile
    private var isMonitoring = false
    private var audioFocusRequest: AudioFocusRequest? = null

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        Log.d(TAG, "onAudioFocusChange: $focusChange")
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                notifyYield("audio_focus_loss", mapOf("focusChange" to focusChange))
            }
        }
    }

    private val recordingCallback = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: List<AudioRecordingConfiguration>?) {
            super.onRecordingConfigChanged(configs)
            if (configs == null || !isMonitoring) return

            // 1. Android 10+ (API 29+): check if our recording client was silenced by the system
            // due to concurrent capture policy or phone call / assistant priority.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val silenced = configs.any { it.isClientSilenced }
                if (silenced) {
                    Log.d(TAG, "Active recording configuration silenced by system")
                    notifyYield("recording_silenced", null)
                    return
                }
            }

            // 2. Concurrency: another app has started capturing audio across the system.
            // If there are multiple active recording configs while Ayma is holding the mic,
            // another app is capturing audio.
            if (configs.size > 1) {
                Log.d(TAG, "Concurrent recording detected: count=${configs.size}")
                notifyYield("recording_concurrency", mapOf("count" to configs.size))
                return
            }
        }
    }

    fun attach() {
        channel = MethodChannel(messenger, CHANNEL_NAME).apply {
            setMethodCallHandler(this@MicYieldManager)
        }
        try {
            audioManager.registerAudioRecordingCallback(recordingCallback, mainHandler)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to register audio recording callback", e)
        }
    }

    fun detach() {
        stopMonitoring()
        try {
            audioManager.unregisterAudioRecordingCallback(recordingCallback)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to unregister audio recording callback", e)
        }
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startMonitoring" -> {
                startMonitoring()
                result.success(null)
            }
            "stopMonitoring" -> {
                stopMonitoring()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    @Synchronized
    private fun startMonitoring() {
        if (isMonitoring) return
        isMonitoring = true
        Log.d(TAG, "startMonitoring: acquiring audio focus")
        requestAudioFocusInternal()
    }

    @Synchronized
    private fun stopMonitoring() {
        if (!isMonitoring) return
        isMonitoring = false
        Log.d(TAG, "stopMonitoring: abandoning audio focus")
        abandonAudioFocusInternal()
    }

    private fun requestAudioFocusInternal() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val attributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(attributes)
                    .setAcceptsDelayedFocusGain(false)
                    .setOnAudioFocusChangeListener(focusChangeListener, mainHandler)
                    .build()
                audioFocusRequest = request
                val res = audioManager.requestAudioFocus(request)
                if (res == AudioManager.AUDIOFOCUS_REQUEST_FAILED) {
                    Log.d(TAG, "requestAudioFocus failed, another app has exclusive focus")
                    notifyYield("audio_focus_denied", null)
                }
            } else {
                @Suppress("DEPRECATION")
                val res = audioManager.requestAudioFocus(
                    focusChangeListener,
                    AudioManager.STREAM_VOICE_CALL,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                )
                if (res == AudioManager.AUDIOFOCUS_REQUEST_FAILED) {
                    Log.d(TAG, "requestAudioFocus failed, another app has exclusive focus")
                    notifyYield("audio_focus_denied", null)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to request audio focus", e)
        }
    }

    private fun abandonAudioFocusInternal() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let {
                    audioManager.abandonAudioFocusRequest(it)
                    audioFocusRequest = null
                }
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(focusChangeListener)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to abandon audio focus", e)
        }
    }

    @Synchronized
    private fun notifyYield(reason: String, details: Map<String, Any?>?) {
        if (!isMonitoring) return
        isMonitoring = false
        abandonAudioFocusInternal()
        mainHandler.post {
            val payload = mutableMapOf<String, Any?>("reason" to reason)
            if (details != null) payload.putAll(details)
            channel?.invokeMethod("onMicYielded", payload)
        }
    }
}
