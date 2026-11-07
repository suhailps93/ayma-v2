package com.ayma.ayma_flutter

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.role.RoleManager
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import android.app.Activity
import android.media.projection.MediaProjectionManager
import android.net.Uri
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
        const val KEYBOARD_DRAFT_CHANNEL = "ayma/keyboard_draft"
        const val COPILOT_CHANNEL = "ayma/copilot"
        const val COPILOT_CAPTURE_REQUEST = 9021

        /** Default-assistant channel: Dart's `AssistantService`. */
        const val ASSISTANT_CHANNEL = "ayma/assistant"

        /** Action [AymaAssistantSession] launches this activity with. */
        const val ACTION_ASSIST_LAUNCH =
            "com.ayma.ayma_flutter.action.ASSIST_LAUNCH"

        /** Boolean extra marking an intent as an assistant summon. */
        const val EXTRA_FROM_ASSISTANT = "from_assistant"

        /** Request code for the ROLE_ASSISTANT role-request intent. */
        const val ASSISTANT_ROLE_REQUEST = 9022

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
    private var assistantChannel: MethodChannel? = null

    /** The pending Dart requestCapture call, completed by the
     *  MediaProjection consent result in [onActivityResult]. */
    private var copilotCaptureResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureDefaultPushChannel()
        noteAssistantIntent(intent)
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
        if (isAssistantIntent(intent)) {
            noteAssistantIntent(intent)
            assistantChannel?.invokeMethod("onAssistSummon", null)
        }
    }

    /** True when [intent] is an assistant summon reaching this activity:
     *  launched by [AymaAssistantSession], or a system ACTION_ASSIST. */
    private fun isAssistantIntent(intent: Intent?): Boolean =
        intent?.action == ACTION_ASSIST_LAUNCH ||
            intent?.action == Intent.ACTION_ASSIST ||
            intent?.getBooleanExtra(EXTRA_FROM_ASSISTANT, false) == true

    /**
     * For a bare ACTION_ASSIST launch (some launchers route the gesture
     * to the activity instead of the voice-interaction session) there
     * is no AssistBridge snapshot: seed an empty one so Dart opens the
     * assistant surface in its "could not see that screen" state
     * rather than dropping the summon. A real session snapshot is
     * already in the bridge and is never overwritten here.
     */
    private fun noteAssistantIntent(intent: Intent?) {
        if (!isAssistantIntent(intent)) return
        if (AssistBridge.peek() != null) return
        if (intent?.action == ACTION_ASSIST_LAUNCH) return
        AssistBridge.store(
            AssistSnapshotData(
                capturedAtMillis = System.currentTimeMillis(),
                screenDataAllowed = false,
                source = "assist_intent",
            )
        )
    }

    /** True when Ayma is the device's default digital assistant. */
    private fun isDefaultAssistant(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager =
                getSystemService(Context.ROLE_SERVICE) as? RoleManager
            if (roleManager != null &&
                roleManager.isRoleAvailable(RoleManager.ROLE_ASSISTANT) &&
                roleManager.isRoleHeld(RoleManager.ROLE_ASSISTANT)
            ) {
                return true
            }
        }
        val mine = ComponentName(this, AymaAssistantService::class.java)
        val voiceService = Settings.Secure.getString(
            contentResolver, "voice_interaction_service"
        )
        if (voiceService == mine.flattenToString() ||
            voiceService == mine.flattenToShortString()
        ) {
            return true
        }
        val assistant = Settings.Secure.getString(contentResolver, "assistant")
        return assistant?.contains(packageName) == true
    }

    /**
     * Deep-links to the system UI for choosing the default assistant:
     * the ROLE_ASSISTANT request dialog on Android 10+ (one tap for
     * the user to confirm), else the default-apps settings page, else
     * the voice-input settings page.
     */
    private fun openDefaultAssistantSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roleManager =
                getSystemService(Context.ROLE_SERVICE) as? RoleManager
            if (roleManager != null &&
                roleManager.isRoleAvailable(RoleManager.ROLE_ASSISTANT) &&
                !roleManager.isRoleHeld(RoleManager.ROLE_ASSISTANT)
            ) {
                @Suppress("DEPRECATION")
                startActivityForResult(
                    roleManager.createRequestRoleIntent(
                        RoleManager.ROLE_ASSISTANT
                    ),
                    ASSISTANT_ROLE_REQUEST,
                )
                return
            }
        }
        val intents = listOf(
            Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS),
            Intent(Settings.ACTION_VOICE_INPUT_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (candidate in intents) {
            try {
                startActivity(
                    candidate.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                return
            } catch (e: Exception) {
                // Try the next settings surface.
            }
        }
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

        // Ayma Keyboard V1 draft plumbing: the Flutter side writes the
        // current draft to the app-internal file the IME reads (same
        // application, same sandbox — see KeyboardDraftStore). It can
        // also open the system keyboard settings and the keyboard
        // picker for the explainer screen. No draft text is logged.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            KEYBOARD_DRAFT_CHANNEL
        ).setMethodCallHandler { call, result ->
            val store = KeyboardDraftFile(filesDir)
            when (call.method) {
                "setDraft" -> {
                    val text = call.argument<String>("text")
                    val created = call.argument<Number>("createdAtMillis")
                    if (text.isNullOrBlank() || created == null) {
                        result.success(false)
                    } else {
                        store.write(
                            KeyboardDraft(
                                text,
                                created.toLong(),
                                call.argument<String>("source")
                            )
                        )
                        result.success(true)
                    }
                }
                "getDraft" -> result.success(store.read()?.encode())
                "clearDraft" -> {
                    store.clear()
                    result.success(null)
                }
                "openKeyboardSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(true)
                }
                "showKeyboardPicker" -> {
                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE)
                        as InputMethodManager
                    imm.showInputMethodPicker()
                    result.success(true)
                }
                else -> result.notImplemented()
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

        // Screen co-pilot (MediaProjection + highlight overlay). Dart's
        // CopilotService drives everything through this one channel; the
        // capture service itself calls back on the same channel name via
        // the cached engine (see CopilotProjectionService.invokeDart).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            COPILOT_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canDrawOverlays" ->
                    result.success(CopilotOverlay.canDraw(this))
                "openOverlaySettings" -> {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:$packageName")
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(null)
                }
                "openAppInfo" -> {
                    // The Restricted Settings recovery route: App info is
                    // where the three-dot menu -> "Allow restricted
                    // settings" lives for sideloaded installs.
                    val intent = Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName")
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(null)
                }
                "installerPackage" -> {
                    // Who installed Ayma (Play = com.android.vending);
                    // anything else (or unknown) means sideloaded, which is
                    // what triggers Android's Restricted Settings lock on
                    // the overlay permission.
                    val installer = try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            packageManager
                                .getInstallSourceInfo(packageName)
                                .installingPackageName
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getInstallerPackageName(packageName)
                        }
                    } catch (e: Exception) {
                        null
                    }
                    result.success(installer)
                }
                "requestCapture" -> {
                    if (copilotCaptureResult != null) {
                        result.error("BUSY", "a capture request is already pending", null)
                    } else {
                        copilotCaptureResult = result
                        val manager = getSystemService(
                            Context.MEDIA_PROJECTION_SERVICE
                        ) as MediaProjectionManager
                        @Suppress("DEPRECATION")
                        startActivityForResult(
                            manager.createScreenCaptureIntent(),
                            COPILOT_CAPTURE_REQUEST
                        )
                    }
                }
                "stopSharing" -> {
                    startService(
                        Intent(this, CopilotProjectionService::class.java)
                            .setAction(CopilotProjectionService.ACTION_STOP)
                    )
                    CopilotOverlay.hideAll(this)
                    result.success(null)
                }
                "isSharing" -> result.success(CopilotProjectionService.isRunning)
                "showHighlight" -> {
                    val x = call.argument<Double>("x")?.toFloat() ?: 0f
                    val y = call.argument<Double>("y")?.toFloat() ?: 0f
                    val w = call.argument<Double>("w")?.toFloat() ?: 0f
                    val h = call.argument<Double>("h")?.toFloat() ?: 0f
                    val label = call.argument<String>("label")
                    CopilotOverlay.showHighlight(this, x, y, w, h, label)
                    result.success(null)
                }
                "clearHighlight" -> {
                    CopilotOverlay.hideHighlight(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // Default digital assistant (Assist API). Dart's AssistantService
        // reads the one-shot summon snapshot from AssistBridge through
        // this channel; the native session already stored it before
        // launching this activity. Warm summons also get an
        // "onAssistSummon" invoke (see onNewIntent); a cold-start
        // summon is picked up by Dart's initial takePendingAssist,
        // because this invoke can race handler registration.
        assistantChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ASSISTANT_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isDefaultAssistant" ->
                        result.success(isDefaultAssistant())
                    "openDefaultAssistantSettings" -> {
                        openDefaultAssistantSettings()
                        result.success(true)
                    }
                    "takePendingAssist" ->
                        result.success(AssistBridge.take()?.toMap())
                    "hasPendingAssist" ->
                        result.success(AssistBridge.peek() != null)
                    "clearPendingAssist" -> {
                        AssistBridge.clear()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        if (isAssistantIntent(intent)) {
            assistantChannel?.invokeMethod("onAssistSummon", null)
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

    @Deprecated("MediaProjection consent still arrives here")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != COPILOT_CAPTURE_REQUEST) return
        val pending = copilotCaptureResult
        copilotCaptureResult = null
        if (resultCode == Activity.RESULT_OK && data != null) {
            val intent = Intent(this, CopilotProjectionService::class.java).apply {
                action = CopilotProjectionService.ACTION_START
                putExtra(CopilotProjectionService.EXTRA_RESULT_CODE, resultCode)
                putExtra(CopilotProjectionService.EXTRA_RESULT_DATA, data)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            pending?.success(true)
        } else {
            pending?.success(false)
        }
    }

    private fun startCallService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
