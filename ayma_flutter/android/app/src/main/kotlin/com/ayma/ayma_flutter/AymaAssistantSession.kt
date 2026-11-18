package com.ayma.ayma_flutter

import android.app.assist.AssistContent
import android.app.assist.AssistStructure
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.voice.VoiceInteractionSession
import android.view.Gravity
import android.view.View
import android.widget.TextView
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.ByteArrayOutputStream
import kotlin.math.roundToInt

/**
 * One assistant summon. Android creates this session when the user
 * long-presses Home (or uses the assistant gesture) while Ayma is the
 * default digital assistant.
 *
 * Behaviour (founder order, Nov 2026): a summon raises a FLOATING AYMA ORB
 * over the current app and starts voice mode in the BACKGROUND — the full app
 * Activity is NOT launched. The orb is the real [AymaOrb] widget running the
 * real LiveKit voice stack, rendered by a [FlutterEngine] on the
 * `assistantOrbMain` Dart entrypoint, hosted inside THIS session's own window
 * (the only surface — no SYSTEM_ALERT_WINDOW overlay). Dismissing the orb
 * finishes the session and returns the user to the app they were in.
 *
 * Screen-context data flow is UNCHANGED (the sanctioned Assist API route): the
 * system hands this session the foreground app's [AssistContent],
 * [AssistStructure] and a screenshot — only when the user enabled "Use screen
 * and app data" for Ayma. We read them once, hold the result in memory
 * ([AssistBridge]); the orb's Dart reads it back over `ayma/assistant` and
 * folds it into the voice session's context. No Accessibility service, no
 * background capture, no storage.
 *
 * Implementation note: only the long-standing callbacks are overridden.
 * On Android 11+ the framework's default `onHandleAssist(AssistState)`
 * unpacks the state and calls exactly these, so one code path serves
 * every API level from minSdk 26 up.
 */
class AymaAssistantSession(context: Context) : VoiceInteractionSession(context) {

    companion object {
        /// How long to wait for the separate screenshot callback before
        /// storing whatever the assist payload already carried.
        private const val FLUSH_DELAY_MS = 450L

        /// Screenshot downscale cap (same posture as the co-pilot share).
        private const val MAX_SCREENSHOT_WIDTH = 720
        private const val SCREENSHOT_JPEG_QUALITY = 70

        /// Traversal caps so a hostile or pathological hierarchy cannot
        /// stall the summon.
        private const val MAX_NODES = 300
        private const val MAX_DEPTH = 24

        /// The Dart entrypoint the orb engine runs — a single overlay surface,
        /// never the full app `main()`.
        private const val ORB_ENTRYPOINT = "assistantOrbMain"

        /// Channel the orb's Dart uses to ask the session to close (returning
        /// the user to the app they summoned from).
        private const val ORB_CHANNEL = "ayma/assistant_orb"
    }

    private val handler = Handler(Looper.getMainLooper())

    private var foregroundPackage = ""
    private var webUri = ""
    private var structuredData = ""
    private var texts: List<String> = emptyList()
    private var screenDataAllowed = false
    private var screenshotBytes: ByteArray? = null
    private var screenshotWidth = 0
    private var screenshotHeight = 0
    private var flushScheduled = false
    private var flushed = false

    private var flutterEngine: FlutterEngine? = null
    private var flutterView: FlutterView? = null
    private var assistChannel: MethodChannel? = null
    private var orbChannel: MethodChannel? = null

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        if (showFlags and SHOW_WITH_ASSIST != 0 ||
            showFlags and SHOW_WITH_SCREENSHOT != 0
        ) {
            // The payload itself arrives via onHandleAssist /
            // onHandleScreenshot; make sure a flush is pending even if
            // only one of them fires.
            scheduleFlush()
        }
        // Boot the floating orb straight away: the engine warms (Firebase init,
        // auth restore, LiveKit connect) in parallel with the ~450ms assist
        // flush window, and the orb's Dart polls AssistBridge for the snapshot.
        startOrb()
    }

    override fun onHide() {
        super.onHide()
        handler.removeCallbacksAndMessages(null)
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        teardownOrb()
        super.onDestroy()
    }

    @Deprecated("Framework unpacks AssistState into this on API 30+")
    override fun onHandleAssist(
        args: Bundle?,
        structure: AssistStructure?,
        content: AssistContent?,
    ) {
        if (structure != null || content != null) screenDataAllowed = true
        foregroundPackage = structure?.activityComponent?.packageName ?: ""
        webUri = content?.webUri?.toString() ?: ""
        structuredData = content?.structuredData ?: ""
        texts = AssistTextFlattener.flatten(readStructure(structure))
        scheduleFlush()
    }

    override fun onHandleScreenshot(screenshot: Bitmap?) {
        if (screenshot != null) {
            screenDataAllowed = true
            encodeScreenshot(screenshot)
        }
        scheduleFlush()
    }

    private fun scheduleFlush() {
        if (flushed || flushScheduled) return
        flushScheduled = true
        handler.postDelayed({ flush() }, FLUSH_DELAY_MS)
    }

    /**
     * Stores the captured screen snapshot in [AssistBridge] for the orb's Dart
     * to read over `ayma/assistant`. It no longer launches [MainActivity] — the
     * summon is served entirely by the in-session floating orb ([startOrb]).
     */
    private fun flush() {
        if (flushed) return
        flushed = true
        AssistBridge.store(
            AssistSnapshotData(
                foregroundPackage = foregroundPackage,
                webUri = webUri,
                structuredData = structuredData,
                texts = texts,
                screenshotBytes = screenshotBytes,
                screenshotWidth = screenshotWidth,
                screenshotHeight = screenshotHeight,
                capturedAtMillis = System.currentTimeMillis(),
                screenDataAllowed = screenDataAllowed,
                source = "voice_interaction",
            )
        )
    }

    /**
     * Creates the FlutterEngine + transparent FlutterView that renders the
     * floating orb, and shows it as this session's content. On any failure the
     * session falls back to an honest text view rather than a silent blank
     * window (AGENTS.md: never a silent hang when the brain can't come up).
     */
    private fun startOrb() {
        if (flutterEngine != null) return
        try {
            val engine = FlutterEngine(context.applicationContext)
            GeneratedPluginRegistrant.registerWith(engine)

            // Register the session's channels BEFORE running Dart so the orb's
            // first calls (snapshot read, dismiss) always resolve.
            val messenger = engine.dartExecutor.binaryMessenger
            assistChannel = MethodChannel(messenger, MainActivity.ASSISTANT_CHANNEL).also {
                it.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "takePendingAssist" -> result.success(AssistBridge.take()?.toMap())
                        "hasPendingAssist" -> result.success(AssistBridge.peek() != null)
                        else -> result.notImplemented()
                    }
                }
            }
            orbChannel = MethodChannel(messenger, ORB_CHANNEL).also {
                it.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "dismiss" -> {
                            result.success(null)
                            // Close the session window; onDestroy tears the
                            // engine down and the user returns to their app.
                            finish()
                        }
                        else -> result.notImplemented()
                    }
                }
            }

            val appBundlePath =
                FlutterInjector.instance().flutterLoader().findAppBundlePath()
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(appBundlePath, ORB_ENTRYPOINT)
            )

            // Transparent texture surface so only the orb (and the expanded
            // scrim) paints over the foreground app.
            val textureView = FlutterTextureView(context).apply { isOpaque = false }
            val view = FlutterView(context, textureView)
            view.attachToFlutterEngine(engine)
            engine.lifecycleChannel.appIsResumed()

            flutterEngine = engine
            flutterView = view
            setContentView(view)
        } catch (e: Exception) {
            teardownOrb()
            setContentView(buildErrorView())
        }
    }

    private fun teardownOrb() {
        assistChannel?.setMethodCallHandler(null)
        orbChannel?.setMethodCallHandler(null)
        assistChannel = null
        orbChannel = null
        flutterView?.detachFromFlutterEngine()
        flutterView = null
        flutterEngine?.let { engine ->
            engine.lifecycleChannel.appIsDetached()
            engine.destroy()
        }
        flutterEngine = null
    }

    private fun encodeScreenshot(bitmap: Bitmap) {
        val scaled = if (bitmap.width > MAX_SCREENSHOT_WIDTH) {
            val scale = MAX_SCREENSHOT_WIDTH.toFloat() / bitmap.width
            Bitmap.createScaledBitmap(
                bitmap,
                MAX_SCREENSHOT_WIDTH,
                (bitmap.height * scale).roundToInt().coerceAtLeast(1),
                true,
            )
        } else {
            bitmap
        }
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, SCREENSHOT_JPEG_QUALITY, out)
        screenshotBytes = out.toByteArray()
        screenshotWidth = scaled.width
        screenshotHeight = scaled.height
        if (scaled !== bitmap) scaled.recycle()
    }

    /// Thin AssistStructure -> [AssistNodeData] traversal (capped).
    private fun readStructure(structure: AssistStructure?): AssistNodeData? {
        if (structure == null || structure.windowNodeCount == 0) return null
        var visited = 0
        fun convert(node: AssistStructure.ViewNode, depth: Int): AssistNodeData {
            visited++
            val children = mutableListOf<AssistNodeData>()
            if (depth < MAX_DEPTH) {
                for (i in 0 until node.childCount) {
                    if (visited >= MAX_NODES) break
                    children.add(convert(node.getChildAt(i), depth + 1))
                }
            }
            return AssistNodeData(
                text = node.text?.toString(),
                contentDescription = node.contentDescription?.toString(),
                className = node.className,
                children = children,
            )
        }
        return convert(structure.getWindowNodeAt(0).rootViewNode, 0)
    }

    /// Honest fallback shown only if the orb engine could not be created.
    private fun buildErrorView(): View {
        return TextView(context).apply {
            text = "Ayma couldn't start here. Open the app to talk to her."
            setTextColor(Color.WHITE)
            textSize = 15f
            gravity = Gravity.CENTER
            setBackgroundColor(Color.rgb(26, 23, 20))
            setPadding(48, 48, 48, 48)
        }
    }
}
