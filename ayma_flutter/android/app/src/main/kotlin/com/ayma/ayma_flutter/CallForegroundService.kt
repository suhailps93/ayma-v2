package com.ayma.ayma_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat
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
        // v2: the original "ayma_call_channel" was created with
        // IMPORTANCE_LOW, which is why it landed under the shade's "Silent"
        // header with its action buttons hidden on the founder's Pixel.
        // Android never lets an app change a channel's importance once
        // created — re-creating the same id with a new importance is a
        // silent no-op on any device that already has it — so this must be
        // a new channel id, not a tweaked one, to actually take effect on
        // an existing install. The legacy id is deleted below on first run
        // after the update so it doesn't linger as a dead duplicate in
        // Settings > Notifications.
        private const val LEGACY_CHANNEL_ID = "ayma_call_channel"
        const val CHANNEL_ID = "ayma_call_channel_v2"
        private const val NOTIFICATION_ID = 4242

        const val ACTION_STOP = "com.ayma.ayma_flutter.action.STOP"
        const val ACTION_HANG_UP = "com.ayma.ayma_flutter.action.HANG_UP"
        const val ACTION_TOGGLE_MUTE = "com.ayma.ayma_flutter.action.TOGGLE_MUTE"

        const val EXTRA_STATUS = "status"
        const val EXTRA_MUTED = "muted"
        const val EXTRA_START_TIME = "startTimeMillis"

        const val ENGINE_CACHE_ID = "ayma_main_engine"
        const val METHOD_CHANNEL = "ayma/call_ui"
    }

    private var status = "Voice call"
    private var muted = false

    // Wall-clock start time fed to Notification.Builder#setWhen so the OS
    // renders a live, always-accurate MM:SS via setUsesChronometer(true) —
    // the system UI ticks this itself from elapsedRealtime, so it keeps
    // counting correctly even if the app's background Dart isolate gets
    // throttled and stops sending "update" calls. Defaults to "now" so the
    // very first startForeground() (before Dart's start payload lands) still
    // shows a sane chronometer instead of a null/garbage base.
    private var startTimeMillis = System.currentTimeMillis()

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
        if (intent?.hasExtra(EXTRA_START_TIME) == true) {
            startTimeMillis = intent.getLongExtra(EXTRA_START_TIME, startTimeMillis)
        }

        // Every branch calls startForeground() immediately, including the
        // stop path — Android expects it within 5s of any
        // startForegroundService() call targeting this service, even one
        // that's already running in the foreground.
        //
        // A microphone-typed FGS additionally requires the caller to already
        // be in an "eligible state" (Dart's CallBackgroundService now starts
        // this the moment a call goes live, never reactively on
        // backgrounding, specifically to satisfy that). If that invariant is
        // ever violated anyway — an OS/OEM edge case, a revoked permission
        // mid-call — Android throws an uncaught SecurityException here that
        // would otherwise crash the ENTIRE app with no chance to recover
        // (confirmed on-device, 2026-09-13: "Ayma keeps stopping" on every
        // backgrounded call). A missing notification is a much smaller
        // failure than losing the whole app mid-conversation.
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (e: Exception) {
            invokeDart("startFailed")
            stopSelf()
            return START_NOT_STICKY
        }

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
            manager.getNotificationChannel(LEGACY_CHANNEL_ID)?.let {
                manager.deleteNotificationChannel(LEGACY_CHANNEL_ID)
            }
            // IMPORTANCE_DEFAULT, not _LOW: an ongoing-call notification
            // needs to land in the shade's normal section, not get
            // auto-bucketed under "Silent" (which also collapses it to a
            // single line with no visible action buttons) — that
            // miscategorization was the root cause of both the "Silent"
            // placement and the missing Hang Up / Mute pills the founder
            // saw on-device.
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Voice call",
                        NotificationManager.IMPORTANCE_DEFAULT
                    ).apply {
                        description = "Ongoing Ayma voice call"
                        setShowBadge(false)
                    }
                )
            }
        }
    }

    // Renders the caller avatar shown in the CallStyle Person icon: the same
    // Cherry Fuchsia orb as the launcher icon (see the "logo within logo"
    // comment above), with a small solid-green "online" badge composited
    // onto its bottom-right corner — the founder's requested treatment,
    // handed over as a manually-edited mockup screenshot (a green dot on
    // the avatar, the same convention messaging apps use for an online
    // status indicator).
    //
    // R.mipmap.ic_launcher is an adaptive icon on API 26+ (a background
    // color layer plus an inset foreground drawable, resolved to a flat PNG
    // per-density below that) and IconCompat.loadDrawable() correctly
    // resolves either form for us. Drawing it straight to a canvas paints
    // the full square (background + foreground, unmasked), so it is
    // explicitly clipped to a circle here first — both to match the
    // circular avatar the founder's original screenshot already shows, and
    // so the badge below has a well-defined circular boundary to sit on
    // regardless of whatever additional circular mask CallLayout applies
    // upstream to the Person icon.
    private fun buildCallerIcon(): IconCompat {
        val size = 256 // px; comfortably above any on-screen avatar size so
                        // the badge stays crisp up to xxxhdpi.
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val avatarRadius = size / 2f

        val baseDrawable = IconCompat.createWithResource(this, R.mipmap.ic_launcher)
            .loadDrawable(this)
        if (baseDrawable != null) {
            val clipPath = Path().apply {
                addCircle(avatarRadius, avatarRadius, avatarRadius, Path.Direction.CW)
            }
            val saveCount = canvas.save()
            canvas.clipPath(clipPath)
            baseDrawable.setBounds(0, 0, size, size)
            baseDrawable.draw(canvas)
            canvas.restoreToCount(saveCount)
        }

        // Badge geometry: sized to ~26% of the avatar's diameter (within
        // the founder's requested 25-30% range), centered on the
        // down-right 45deg radial from the avatar's center, and pulled in
        // just far enough that the badge's own outer edge (border
        // included) is internally tangent to the avatar's circle — i.e.
        // the whole badge is guaranteed to land inside the visible orb,
        // never clipped off by a further system-level circular mask.
        val badgeRadius = size * 0.13f
        val borderWidth = size * 0.035f
        val badgeOuterRadius = badgeRadius + borderWidth
        val centerDistance = avatarRadius - badgeOuterRadius
        val angleRad = Math.toRadians(45.0)
        val badgeCenterX = avatarRadius + (centerDistance * Math.cos(angleRad)).toFloat()
        val badgeCenterY = avatarRadius + (centerDistance * Math.sin(angleRad)).toFloat()

        // White border, the near-universal choice for an avatar "online"
        // dot (WhatsApp/Messenger/Slack/Teams) — unlike a dark border, it
        // reads correctly whether the shade is rendered in light or dark
        // system theme.
        val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.FILL
        }
        // Same ongoing-call green already used for this notification's
        // accent color / mic badge below.
        val badgePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#34A853")
            style = Paint.Style.FILL
        }
        canvas.drawCircle(badgeCenterX, badgeCenterY, badgeOuterRadius, borderPaint)
        canvas.drawCircle(badgeCenterX, badgeCenterY, badgeRadius, badgePaint)

        return IconCompat.createWithBitmap(bitmap)
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

        // "logo within logo": CallStyle unconditionally badges the small
        // icon over the Person's large icon at the OS layer
        // (com.android.internal.widget.CallLayout, compiled into AOSP,
        // unreachable from any NotificationCompat public API — confirmed by
        // reading the platform source, not guessed). That badge cannot be
        // suppressed, so a prior fix made the large icon fully transparent
        // to avoid two overlapping circles — founder call: he'd rather see
        // the real logo with a small badge on its corner than no logo at
        // all. Same real Cherry Fuchsia orb as the launcher icon, not a
        // separate asset to keep in sync.
        val caller = Person.Builder()
            .setName("Ayma")
            .setImportant(true)
            .setIcon(buildCallerIcon())
            .build()
        val muteIcon = if (muted) R.drawable.ic_call_mic_off else R.drawable.ic_call_mic
        val muteAction = NotificationCompat.Action.Builder(
            muteIcon,
            if (muted) "Unmute" else "Mute",
            mutePendingIntent
        ).build()

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Ayma")
            .setContentText(status)
            // A plain white silhouette (a mic), rendered as the badge chip
            // on the logo's corner (see the Person icon comment above).
            .setSmallIcon(R.drawable.ic_notification)
            // Without an explicit color, Android tints the small icon/badge
            // using the app's theme accent — Cherry Fuchsia, which read as
            // an odd pink dot on the badge. Ongoing-call green instead.
            .setColor(Color.parseColor("#34A853"))
            // CallStyle (androidx.core, compat back to API 21) is what
            // actually renders the red Hang Up / green Mute pill treatment
            // the founder pointed at in ChatGPT's reference — a plain
            // .addAction() pair on a CATEGORY_CALL notification will show as
            // ordinary text buttons, not the call-styled pills.
            .setStyle(
                NotificationCompat.CallStyle.forOngoingCall(caller, hangUpPendingIntent)
                    .setIsVideo(false)
            )
            .addAction(muteAction)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(contentPendingIntent)
            // Live, always-accurate MM:SS rendered by the OS itself from
            // elapsedRealtime — see the startTimeMillis doc comment above.
            .setWhen(startTimeMillis)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .build()
    }

    // The call's real state — mic capture, audio playback, the LiveKit
    // connection — all live inside the single Flutter/Dart engine this
    // service only ever relays taps into (see invokeDart below). If the
    // user swipes the app away from Recents, that engine is torn down and
    // there is no live call left behind it — leaving this ongoing
    // notification up would be a zombie ("Ayma · 01:30, Voice call" with
    // nothing actually running). Tear the service down together with the
    // task instead of only reacting to an explicit Hang Up / ACTION_STOP.
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun invokeDart(method: String) {
        val engine = FlutterEngineCache.getInstance().get(ENGINE_CACHE_ID) ?: return
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .invokeMethod(method, null)
    }
}
