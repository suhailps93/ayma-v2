package com.ayma.ayma_flutter

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * Caches this activity's [FlutterEngine] so [CallForegroundService] can call
 * back into the same running Dart isolate (never a second engine), and wires
 * the "ayma/call_ui" channel Dart's `CallBackgroundService` uses to start,
 * update, and stop that service (F4 — background call notification).
 *
 * Also hosts the tiny "ayma/media_save" channel the full-screen image viewer
 * uses to save into the device gallery (MediaStore `Pictures/Ayma`) — a dozen
 * lines here instead of a whole gallery-saver plugin.
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val MEDIA_SAVE_CHANNEL = "ayma/media_save"
        const val PUSH_CHANNEL = "ayma/push"
        const val BADGE_CHANNEL = "ayma/badge"

        /**
         * Notification channel for FCM `notification`-payload pushes the system
         * displays on its own (web-search ready, new match, Ayma check-in …).
         * IMPORTANCE_HIGH so they pop as a heads-up alert, and named by the
         * manifest's `default_notification_channel_id` meta-data. The backend
         * pins each push to it (`ANDROID_DEFAULT_CHANNEL` in
         * notifications_schema.py); keep the two strings equal. DMs render on
         * their own `ayma_dm_messages` channel ([DmMessagingService]).
         */
        const val DEFAULT_CHANNEL_ID = "ayma_default"

        /** True while the app is on screen; [DmMessagingService] posts nothing then. */
        @Volatile
        var isResumed = false
    }

    private var pushChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureDefaultPushChannel()
    }

    /**
     * Creates the IMPORTANCE_HIGH push channel the system displays background
     * notification-payload pushes on. Must exist before any such push arrives
     * (the system builds those notifications itself — no app code runs), so it
     * is created here on every launch; [NotificationManager.createNotificationChannel]
     * is a no-op once the channel exists, and the user's own importance choice
     * is preserved.
     */
    private fun ensureDefaultPushChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(DEFAULT_CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                DEFAULT_CHANNEL_ID, "General", NotificationManager.IMPORTANCE_HIGH
            )
        )
    }

    override fun onResume() {
        super.onResume()
        isResumed = true
    }

    override fun onPause() {
        isResumed = false
        super.onPause()
    }

    /** The DM-notification tap target carried by [intent], consumed once. */
    private fun takeDeepLink(intent: Intent?): String? {
        val link = intent?.getStringExtra(DmMessagingService.EXTRA_DEEP_LINK)
        intent?.removeExtra(DmMessagingService.EXTRA_DEEP_LINK)
        return link?.takeIf { it.isNotEmpty() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        takeDeepLink(intent)?.let { pushChannel?.invokeMethod("onDeepLink", it) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put(
            CallForegroundService.ENGINE_CACHE_ID,
            flutterEngine
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CallForegroundService.METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "update" -> {
                    val status = call.argument<String>("status")
                        ?: "Voice call"
                    val muted = call.argument<Boolean>("muted") ?: false
                    val aymaQuiet = call.argument<Boolean>("aymaQuiet") ?: false
                    val startTimeMillis = call.argument<Number>("startTimeMillis")
                    val intent = Intent(this, CallForegroundService::class.java).apply {
                        putExtra(CallForegroundService.EXTRA_STATUS, status)
                        putExtra(CallForegroundService.EXTRA_MUTED, muted)
                        putExtra(CallForegroundService.EXTRA_AYMA_QUIET, aymaQuiet)
                        if (startTimeMillis != null) {
                            putExtra(
                                CallForegroundService.EXTRA_START_TIME,
                                startTimeMillis.toLong()
                            )
                        }
                    }
                    startCallService(intent)
                    result.success(null)
                }
                "stop" -> {
                    startCallService(
                        Intent(this, CallForegroundService::class.java)
                            .setAction(CallForegroundService.ACTION_STOP)
                    )
                    result.success(null)
                }
                // In-call screen share (feedback item 13): Dart calls these
                // around the LiveKit screen-track publish — start AFTER the
                // MediaProjection consent grant (the service gains the
                // mediaProjection FGS type Android 14 requires before the
                // projection runs), stop when the share ends so the type is
                // dropped again. The service keeps its current status/mute
                // extras when these payloads omit them.
                "startMediaProjectionFgs" -> {
                    startCallService(
                        Intent(this, CallForegroundService::class.java).apply {
                            putExtra(CallForegroundService.EXTRA_SCREEN_SHARING, true)
                        }
                    )
                    result.success(null)
                }
                "stopMediaProjectionFgs" -> {
                    startCallService(
                        Intent(this, CallForegroundService::class.java).apply {
                            putExtra(CallForegroundService.EXTRA_SCREEN_SHARING, false)
                        }
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        pushChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PUSH_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialDeepLink" -> result.success(takeDeepLink(intent))
                    else -> result.notImplemented()
                }
            }
        }

        // App-icon badge sync (§7.6). The in-app bell's unread count is mirrored
        // here on every tap-driven mark-read so the OS badge matches the app.
        // Android has no portable numeric app-icon badge API (it is launcher-
        // specific and needs a badge library); the launcher's unread dot tracks
        // active shade notifications, which auto-cancel when the user taps one.
        // When the count drops to 0 we clear any notifications still in our
        // default channel so a stale entry doesn't keep the dot lit. The call is
        // acknowledged on both platforms so the shared Dart path stays uniform.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BADGE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setBadge" -> {
                    val count = call.argument<Int>("count") ?: 0
                    if (count <= 0) {
                        val manager = getSystemService(Context.NOTIFICATION_SERVICE)
                            as NotificationManager
                        manager.cancel(DEFAULT_CHANNEL_ID.hashCode())
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_SAVE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveImage" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val name = call.argument<String>("name")
                        ?: "ayma_${System.currentTimeMillis()}.jpg"
                    val mime = call.argument<String>("mime") ?: "image/jpeg"
                    if (bytes == null) {
                        result.error("ARGS", "missing image bytes", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(saveImageToGallery(bytes, name, mime))
                    } catch (e: SecurityException) {
                        result.error("PERMISSION", e.message, null)
                    } catch (e: Exception) {
                        result.error("SAVE_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Writes [bytes] as an image named [name] into the gallery under
     * `Pictures/Ayma` and returns that human-readable location. API 29+ goes
     * through scoped MediaStore (no permission); API 24–28 writes the public
     * Pictures directory, which needs WRITE_EXTERNAL_STORAGE — thrown as
     * [SecurityException] so Dart can request it and retry.
     */
    private fun saveImageToGallery(bytes: ByteArray, name: String, mime: String): String {
        val location = "Pictures/Ayma"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, mime)
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/Ayma"
                )
            }
            val uri = contentResolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
            ) ?: throw IOException("MediaStore insert failed")
            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IOException("MediaStore open failed")
        } else {
            if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                != PackageManager.PERMISSION_GRANTED
            ) {
                throw SecurityException("WRITE_EXTERNAL_STORAGE not granted")
            }
            val dir = File(
                Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_PICTURES
                ),
                "Ayma"
            )
            if (!dir.exists() && !dir.mkdirs()) throw IOException("mkdirs failed")
            File(dir, name).writeBytes(bytes)
            MediaScannerConnection.scanFile(
                this, arrayOf(File(dir, name).absolutePath), arrayOf(mime), null
            )
        }
        return location
    }

    private fun startCallService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
