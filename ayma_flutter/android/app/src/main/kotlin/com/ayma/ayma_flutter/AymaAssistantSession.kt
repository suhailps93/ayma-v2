package com.ayma.ayma_flutter

import android.app.assist.AssistContent
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.voice.VoiceInteractionSession
import android.view.Gravity
import android.view.View
import android.widget.TextView
import java.io.ByteArrayOutputStream
import kotlin.math.roundToInt

/**
 * One assistant summon. Android creates this session when the user
 * long-presses Home (or uses the assistant gesture) while Ayma is the
 * default digital assistant.
 *
 * Data flow, and ONLY this flow (the sanctioned Assist API route):
 * the system hands this session the foreground app's [AssistContent],
 * [AssistStructure] and a screenshot — and only when the user enabled
 * "Use screen and app data" for Ayma. We read them once, hold the result
 * in memory ([AssistBridge]), open [MainActivity] on the assistant
 * surface, and finish. No Accessibility service, no background capture,
 * no storage: if the user never summons, this code never sees a screen.
 *
 * Implementation note: only the long-standing callbacks are overridden.
 * On Android 11+ the framework's default `onHandleAssist(AssistState)`
 * unpacks the state and calls exactly these, so one code path serves
 * every API level from minSdk 26 up.
 */
class AymaAssistantSession(context: Context) : VoiceInteractionSession(context) {

    companion object {
        /// How long to wait for the separate screenshot callback before
        /// opening Ayma with whatever the assist payload already carried.
        private const val FLUSH_DELAY_MS = 450L

        /// Screenshot downscale cap (same posture as the co-pilot share).
        private const val MAX_SCREENSHOT_WIDTH = 720
        private const val SCREENSHOT_JPEG_QUALITY = 70

        /// Traversal caps so a hostile or pathological hierarchy cannot
        /// stall the summon.
        private const val MAX_NODES = 300
        private const val MAX_DEPTH = 24
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
        setContentView(buildLoadingView())
    }

    override fun onHide() {
        super.onHide()
        // The session window went away without a flush (user backed
        // out): nothing is handed to the app.
        handler.removeCallbacksAndMessages(null)
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
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
        val intent = Intent(context, MainActivity::class.java).apply {
            action = MainActivity.ACTION_ASSIST_LAUNCH
            putExtra(MainActivity.EXTRA_FROM_ASSISTANT, true)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }
        try {
            context.startActivity(intent)
        } finally {
            finish()
        }
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

    private fun buildLoadingView(): View {
        return TextView(context).apply {
            text = "Opening Ayma..."
            setTextColor(Color.WHITE)
            textSize = 16f
            gravity = Gravity.CENTER
            setBackgroundColor(Color.rgb(26, 23, 20))
            setPadding(48, 48, 48, 48)
        }
    }
}
