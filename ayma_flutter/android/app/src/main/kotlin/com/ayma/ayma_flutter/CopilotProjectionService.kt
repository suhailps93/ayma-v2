package com.ayma.ayma_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.max

/**
 * Screen-share capture for the co-pilot (MediaProjection).
 *
 * Started ONLY from the in-app co-pilot screen's explicit "Start sharing"
 * action, after the per-session system consent dialog (MainActivity runs
 * createScreenCaptureIntent; the grant lands here as extras). A foreground
 * service of type mediaProjection (Android 14 requirement) owns the
 * projection for the whole share.
 *
 * Frames: an ImageReader over a VirtualDisplay, throttled to ~1 fps,
 * downscaled to <=720px wide, JPEG-encoded, and handed to Dart over the
 * "ayma/copilot" channel. Frames are NEVER written to disk here or stored
 * anywhere — Dart keeps only the latest frame in memory to answer an ask.
 *
 * Safety rails (spec §4):
 *  - **Secure screens pause automatically.** FLAG_SECURE windows (banking,
 *    password fields) render as pure black into a projection. A frame whose
 *    sampled mean luminance is ~0 is never sent on; Dart is told the share
 *    is secure-paused until real frames resume.
 *  - **Screen lock pauses.** ACTION_SCREEN_OFF pauses capture; the share
 *    resumes on ACTION_USER_PRESENT (still the same consent session).
 *  - **Persistent stop.** The foreground notification carries a Stop action
 *    and [CopilotOverlay] shows a tappable stop pill over every app.
 *  - **Task removal stops.** Swiping Ayma away ends the share.
 *  - The projection's own onStop callback (system revoke / consent expiry)
 *    tears everything down and tells Dart.
 */
class CopilotProjectionService : Service() {

    companion object {
        const val CHANNEL_ID = "ayma_copilot_share"
        private const val NOTIFICATION_ID = 4243
        private const val TAG = "CopilotProjection"

        const val ACTION_START = "com.ayma.ayma_flutter.copilot.START"
        const val ACTION_STOP = "com.ayma.ayma_flutter.copilot.STOP"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"

        const val METHOD_CHANNEL = "ayma/copilot"

        /** Mean 0..255 luminance at/below this = a black (secure) frame. */
        private const val BLACK_LUMINANCE_MAX = 4.0
        private const val FRAME_INTERVAL_MS = 1_000L
        private const val MAX_FRAME_WIDTH = 720

        @Volatile
        var isRunning = false
            private set
    }

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var captureThread: HandlerThread? = null
    private var captureHandler: Handler? = null
    private var lastFrameAt = 0L
    private var securePaused = false
    private var screenOff = false

    private val screenStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    screenOff = true
                    invokeDart("onPaused", mapOf("reason" to "screen_lock"))
                }
                Intent.ACTION_USER_PRESENT -> {
                    screenOff = false
                    invokeDart("onResumed", null)
                }
            }
        }
    }
    private var receiverRegistered = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            teardown()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, Int.MIN_VALUE)
            ?: Int.MIN_VALUE
        @Suppress("DEPRECATION")
        val resultData: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            intent?.getParcelableExtra(EXTRA_RESULT_DATA)
        }
        if (resultCode == Int.MIN_VALUE || resultData == null) {
            Log.w(TAG, "start without a projection grant — stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        // Android 14: the FGS must be running (with the mediaProjection
        // type) BEFORE createVirtualDisplay, and the service must be
        // started via startForegroundService from a foreground context —
        // MainActivity does that the moment the consent returns.
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed: ${e.message}")
            invokeDart("onSharingStopped", mapOf("reason" to "foreground_failed"))
            stopSelf()
            return START_NOT_STICKY
        }

        if (projection != null) return START_NOT_STICKY // already sharing
        startCapture(resultCode, resultData)
        isRunning = true
        CopilotOverlay.showStopPill(this) {
            startService(
                Intent(this, CopilotProjectionService::class.java)
                    .setAction(ACTION_STOP)
            )
        }
        invokeDart("onSharingStarted", null)
        return START_NOT_STICKY
    }

    private fun startCapture(resultCode: Int, resultData: Intent) {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
            as MediaProjectionManager
        val proj = manager.getMediaProjection(resultCode, resultData)
        if (proj == null) {
            Log.w(TAG, "getMediaProjection returned null — stopping")
            stopSelf()
            return
        }
        projection = proj
        proj.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                // System revoked the session (or the user stopped it from
                // the system UI): end everything, Dart hears about it in
                // teardown via invokeDart in onDestroy-safe path below.
                Handler(Looper.getMainLooper()).post {
                    teardown()
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }, null)

        val metrics = resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi

        val thread = HandlerThread("ayma-copilot-capture").also { it.start() }
        captureThread = thread
        val handler = Handler(thread.looper)
        captureHandler = handler

        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        imageReader = reader
        reader.setOnImageAvailableListener({ r ->
            if (screenOff) {
                // Locked: drop frames silently; nothing is captured or sent.
                r.acquireLatestImage()?.close()
                return@setOnImageAvailableListener
            }
            val now = System.currentTimeMillis()
            if (now - lastFrameAt < FRAME_INTERVAL_MS) {
                r.acquireLatestImage()?.close()
                return@setOnImageAvailableListener
            }
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            lastFrameAt = now
            try {
                handleFrame(image)
            } catch (e: Exception) {
                Log.w(TAG, "frame handling failed: ${e.message}")
            } finally {
                image.close()
            }
        }, handler)

        virtualDisplay = proj.createVirtualDisplay(
            "ayma-copilot",
            width, height, density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface, null, handler,
        )

        if (!receiverRegistered) {
            registerReceiver(
                screenStateReceiver,
                IntentFilter().apply {
                    addAction(Intent.ACTION_SCREEN_OFF)
                    addAction(Intent.ACTION_USER_PRESENT)
                },
            )
            receiverRegistered = true
        }
    }

    /** Convert one frame, run the black-frame check, ship JPEG to Dart. */
    private fun handleFrame(image: android.media.Image) {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        val rowPadding = rowStride - pixelStride * image.width
        val full = Bitmap.createBitmap(
            image.width + rowPadding / pixelStride, image.height,
            Bitmap.Config.ARGB_8888,
        )
        full.copyPixelsFromBuffer(buffer)
        val bitmap = if (rowPadding == 0) full else Bitmap.createBitmap(
            full, 0, 0, image.width, image.height
        )

        val luminance = meanLuminance(bitmap)
        val isBlack = luminance <= BLACK_LUMINANCE_MAX
        if (isBlack) {
            if (!securePaused) {
                securePaused = true
                invokeDart("onSecurePause", mapOf("paused" to true))
                CopilotOverlay.hideHighlight(this)
            }
            return // a secure frame NEVER leaves the device
        }
        if (securePaused) {
            securePaused = false
            invokeDart("onSecurePause", mapOf("paused" to false))
        }

        val scale = if (bitmap.width > MAX_FRAME_WIDTH) {
            MAX_FRAME_WIDTH.toFloat() / bitmap.width
        } else 1f
        val out = if (scale < 1f) {
            Bitmap.createScaledBitmap(
                bitmap,
                (bitmap.width * scale).toInt().coerceAtLeast(1),
                (bitmap.height * scale).toInt().coerceAtLeast(1),
                true,
            )
        } else bitmap
        val stream = ByteArrayOutputStream()
        out.compress(Bitmap.CompressFormat.JPEG, 70, stream)
        val bytes = stream.toByteArray()
        invokeDart(
            "onFrame",
            mapOf(
                "bytes" to bytes,
                "width" to out.width,
                "height" to out.height,
                // Full-display geometry the coordinate mapper needs: the
                // frame IS the full display (status bar included) at this
                // size, before downscaling.
                "displayWidth" to bitmap.width,
                "displayHeight" to bitmap.height,
                "meanLuminance" to luminance,
            ),
        )
    }

    /** Sampled mean luminance (0..255) over a coarse grid — cheap black check. */
    private fun meanLuminance(bitmap: Bitmap): Double {
        val stepX = max(1, bitmap.width / 48)
        val stepY = max(1, bitmap.height / 48)
        var sum = 0.0
        var count = 0
        var y = 0
        while (y < bitmap.height) {
            var x = 0
            while (x < bitmap.width) {
                val p = bitmap.getPixel(x, y)
                sum += 0.2126 * ((p shr 16) and 0xFF) +
                    0.7152 * ((p shr 8) and 0xFF) +
                    0.0722 * (p and 0xFF)
                count++
                x += stepX
            }
            y += stepY
        }
        return if (count == 0) 255.0 else sum / count
    }

    private fun teardown() {
        if (receiverRegistered) {
            try { unregisterReceiver(screenStateReceiver) } catch (e: Exception) { /* gone */ }
            receiverRegistered = false
        }
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null
        try { projection?.stop() } catch (e: Exception) { /* already stopped */ }
        projection = null
        captureThread?.quitSafely()
        captureThread = null
        captureHandler = null
        if (isRunning) {
            isRunning = false
            CopilotOverlay.hideAll(this)
            invokeDart("onSharingStopped", null)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Ayma swiped away: the share ends with the app task.
        teardown()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Screen share",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ).apply {
                        description = "Ayma screen-share co-pilot is running"
                        setShowBadge(false)
                    }
                )
            }
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, CopilotProjectionService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Ayma is watching your screen")
            .setContentText("She can point at what to tap. Tap Stop to end sharing.")
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(ContextCompat.getColor(this, R.color.ayma_accent))
            .addAction(0, "Stop sharing", stopIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setContentIntent(contentIntent)
            .build()
    }

    /** Relay to Dart on the one cached engine; no-op when it is gone. */
    private fun invokeDart(method: String, args: Any?) {
        val engine = FlutterEngineCache.getInstance()
            .get(CallForegroundService.ENGINE_CACHE_ID) ?: return
        Handler(Looper.getMainLooper()).post {
            MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
                .invokeMethod(method, args, object : MethodChannel.Result {
                    override fun success(result: Any?) {}
                    override fun error(code: String, message: String?, details: Any?) {
                        Log.w(TAG, "$method failed in Dart: $code $message")
                    }
                    override fun notImplemented() {
                        Log.w(TAG, "$method: no Dart handler on $METHOD_CHANNEL")
                    }
                })
        }
    }
}
