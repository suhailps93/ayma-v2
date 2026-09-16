package com.ayma.ayma_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
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

        // Third report of the same "logo within logo" artifact, after two
        // fixes (fc65f01, bd9d047) that only ever touched the SMALL icon's
        // color/shape. Root-caused this time by reading the actual AOSP
        // platform source (frameworks/base) rather than guessing again:
        //
        // CallStyle.forOngoingCall() renders through
        // notification_template_material_call.xml (collapsed) and
        // notification_template_material_big_call.xml (expanded), and BOTH
        // unconditionally <include> notification_template_conversation_icon_container.xml.
        // That layout hard-codes a `conversation_icon_badge` FrameLayout with
        // layout_gravity="end|bottom" — a circular `conversation_badge_background`
        // drawable with the notification's small icon (`R.id.icon`, a
        // NotificationRowIconView) centered inside it — stacked directly on
        // top of the `conversation_icon` (the Person's large icon). This is
        // com.android.internal.widget.CallLayout's job (setData/getConversationIcon),
        // compiled into the OS itself: it is NOT reachable from any
        // NotificationCompat/Notification public API, so no small-icon
        // color or shape change (both already tried) could ever have fixed
        // it — confirmed, not guessed.
        //
        // It also is NOT conditional on us supplying a Person icon at all:
        // CallLayout.getConversationIcon() falls back to
        // PeopleHelper.createAvatarSymbol() — a generated colored circle
        // with the caller's initial — whenever Person.getIcon() is null. So
        // simply omitting .setIcon(...) still leaves a big circle for the
        // badge to sit on and would NOT have fixed this either. The only
        // way to make the avatar area render nothing (so the badge chip is
        // the sole circle, not two nested ones) is to hand CallLayout a
        // non-null icon that paints nothing: a fully transparent bitmap.
        // Trade-off: the peach orb no longer appears in the call
        // notification at all — see the commit message for the full
        // write-up (AOSP source citations included).
        val transparentAvatar = IconCompat.createWithBitmap(
            Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        )
        val caller = Person.Builder()
            .setName("Ayma")
            .setImportant(true)
            .setIcon(transparentAvatar)
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
            // A plain white silhouette. Kept from the earlier fix even
            // though the large icon is now transparent (see the comment on
            // `transparentAvatar` above) — Android still renders this as
            // the lone badge chip in the notification's avatar corner, so
            // it should still read as intentional (a mic), not a stray dot.
            .setSmallIcon(R.drawable.ic_notification)
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
