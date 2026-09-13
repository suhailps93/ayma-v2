package com.ayma.ayma_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Foreground service backing the ongoing "Ayma" call notification shown
 * while a live voice call is backgrounded — title, a live status line, and
 * Hang Up / Mute actions, the Android equivalent of ChatGPT's voice-call
 * notification (see MainShellScreen / CallBackgroundService.dart, F4).
 *
 * Never spins up a second Flutter engine or isolate: it just reaches into
 * the app's single running engine, cached by [MainActivity] in
 * `configureFlutterEngine`, and calls Dart back on the same
 * "ayma/call_ui" [MethodChannel] Dart itself uses to drive this service —
 * so a Hang Up / Mute tap lands on the one live [VoiceSessionController]
 * (com.ayma.ayma_flutter's Dart side), never a state machine of its own.
 */
class CallForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "ayma_call_channel"
        private const val NOTIFICATION_ID = 4242

        const val ACTION_STOP = "com.ayma.ayma_flutter.action.STOP"
        const val ACTION_HANG_UP = "com.ayma.ayma_flutter.action.HANG_UP"
        const val ACTION_TOGGLE_MUTE = "com.ayma.ayma_flutter.action.TOGGLE_MUTE"

        const val EXTRA_STATUS = "status"
        const val EXTRA_MUTED = "muted"

        const val ENGINE_CACHE_ID = "ayma_main_engine"
        const val METHOD_CHANNEL = "ayma/call_ui"
    }

    private var status = "Voice call in progress"
    private var muted = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        intent?.getStringExtra(EXTRA_STATUS)?.let { status = it }
        if (intent?.hasExtra(EXTRA_MUTED) == true) {
            muted = intent.getBooleanExtra(EXTRA_MUTED, muted)
        }

        // Every branch calls startForeground() immediately, including the
        // stop path — Android expects it within 5s of any
        // startForegroundService() call targeting this service, even one
        // that's already running in the foreground.
        startForeground(NOTIFICATION_ID, buildNotification())

        when (action) {
            ACTION_HANG_UP -> invokeDart("hangUp")
            ACTION_TOGGLE_MUTE -> invokeDart("toggleMute")
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Voice call",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Ongoing Ayma voice call"
                    setShowBadge(false)
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val hangUpPendingIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, CallForegroundService::class.java).setAction(ACTION_HANG_UP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val mutePendingIntent = PendingIntent.getService(
            this,
            2,
            Intent(this, CallForegroundService::class.java).setAction(ACTION_TOGGLE_MUTE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Ayma")
            .setContentText(status)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(contentPendingIntent)
            .addAction(0, "Hang Up", hangUpPendingIntent)
            .addAction(0, if (muted) "Unmute" else "Mute", mutePendingIntent)
            .build()
    }

    private fun invokeDart(method: String) {
        val engine = FlutterEngineCache.getInstance().get(ENGINE_CACHE_ID) ?: return
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .invokeMethod(method, null)
    }
}
