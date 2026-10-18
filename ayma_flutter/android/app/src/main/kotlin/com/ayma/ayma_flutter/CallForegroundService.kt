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
import androidx.core.app.Person
import androidx.core.content.ContextCompat
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

        // ── The avatar's bottom-right corner badge: what ACTUALLY feeds it ──
        //
        // CallStyle unconditionally overlays a badge on the Person avatar at
        // the OS layer: in AOSP's notification_template_conversation_icon_
        // container.xml (included by notification_template_material_call.xml)
        // the badge is the view `@id/icon` — a NotificationRowIconView —
        // stacked over `conversation_icon_badge_bg`, an opaque circle tinted
        // to the notification background color (CallLayout#
        // setNotificationBackgroundColor), which is the "dark ring" seen
        // around the badge in dark theme. CallLayout itself never sets the
        // badge's image; there is no public NotificationCompat API that
        // reaches it, hides it, or restyles it. WHAT lands inside it depends
        // on the OS generation (all confirmed by reading the platform
        // source, frameworks/base@main, 2026-09):
        //
        //  * Pre-Android-16-QPR: Notification.Builder#bindSmallIcon binds
        //    the notification's SMALL icon into `@id/icon` and setColor()
        //    tints it — so setSmallIcon(Ayma mark) + setColor(accent)
        //    below renders the mark in the Ayma accent pink inside the dark
        //    ring (the mark is the badge there too).
        //
        //  * Android 16 QPR+ "app icons in notifications" redesign (live on
        //    the founder's Pixel 10 Pro Fold, verified on-device 2026-09-26):
        //    NotificationRowIconView#setImageIcon IGNORES the small icon
        //    whenever SystemUI's injected NotificationIconProvider says so
        //    (flag android.app.Flags.notificationsRedesignAppIcons;
        //    NotificationRowIconViewInflaterFactory), and instead draws the
        //    APP icon — AppIconProvider fetches PackageManager
        //    .getApplicationInfo(pkg).loadUnbadgedIcon() and circle-masks it
        //    via launcher3's BaseIconFactory, cached PER PACKAGE. The
        //    eligibility check (NotificationIconStyleProviderImpl
        //    .shouldShowAppIcon) is true for every app that isn't a headless
        //    system app: it looks only at the package, never at the
        //    notification. Consequences, all verified in source:
        //      - setSmallIcon()/setColor() have NO effect on the badge there
        //        (color overrides are explicitly swallowed while the app
        //        icon shows — NotificationRowIconView#setOriginalIconColor/
        //        #setBackgroundColor stash and ignore them);
        //      - conversation plumbing is irrelevant: we attach no shortcut
        //        or locusId and the badge appears anyway — it is
        //        unconditional in the CallStyle template, not tied to
        //        conversation treatment;
        //      - dropping the Person icon wouldn't help: CallLayout#
        //        getConversationIcon only changes the BIG avatar fallback
        //        (large icon, then a letter avatar), never the badge;
        //      - there is no per-notification/channel opt-out API at all.
        //    So on these builds the badge is, by OS design, a miniature of
        //    the launcher orb inside the dark ring, and nothing this service
        //    can legitimately do changes that. (The only lever that exists —
        //    splitting <application android:icon> from the launcher
        //    <activity android:icon> so ApplicationInfo carries a separate badge glyph —
        //    would also repaint Ayma's icon in Settings and on every other
        //    notification: rejected.)
        //
        // Therefore: only ONE mechanism may ever draw this corner, and it is
        // the OS's. Do NOT resurrect the Canvas-composited dot on the Person
        // bitmap (1d582d6): on QPR+ builds the OS badge is drawn on top of /
        // offset from it and the two stack into the founder's reported
        // "dark circle with a pale checkmark-like curve" double-badge
        // artifact (removed in 327fd2f). The Person icon is a neutral
        // accent disc with a phone glyph (ic_call_avatar), plain resource,
        // no extra compositing: the large avatar must not be the Ayma logo,
        // or the badge would read as a logo inside a logo. The small icon +
        // color below keep the mark badge on every build that still honors
        // them.
        val caller = Person.Builder()
            .setName("Ayma")
            .setImportant(true)
            .setIcon(IconCompat.createWithResource(this, R.drawable.ic_call_avatar))
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
            // The Ayma petal mark (see ic_notification.xml): the status-bar
            // glyph while a call is live, and on pre-Android-16-QPR builds
            // also the avatar's corner badge (see the badge comment above),
            // so the badge is the mark too. On QPR+ builds the OS ignores it
            // for the badge (app icon instead, see above) and it only feeds
            // the status-bar glyph.
            .setSmallIcon(R.drawable.ic_notification)
            // The system tints the small icon with this accent (Cherry
            // Fuchsia, the app accent) in the shade and on the badge.
            .setColor(ContextCompat.getColor(this, R.color.ayma_accent))
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
