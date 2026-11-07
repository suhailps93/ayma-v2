package com.ayma.ayma_flutter

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import androidx.core.content.ContextCompat

/**
 * The co-pilot's two overlay windows (draw-over-apps, granted by the user
 * once via Settings.ACTION_MANAGE_OVERLAY_PERMISSION):
 *
 * 1. The **highlight ring** — a full-screen TYPE_APPLICATION_OVERLAY window
 *    with FLAG_NOT_TOUCHABLE: it is pure paint. The user taps THROUGH it onto
 *    the real control underneath. Ayma draws; she never taps.
 * 2. The **stop pill** — a small, deliberately touchable window pinned to
 *    the top of the screen for the whole share: the persistent stop control
 *    the user can reach from any app.
 *
 * Coordinates the ring receives are already display pixels (Dart maps the
 * backend's normalized coordinates through the frame/display geometry,
 * including status-bar and rotation handling — see copilot_highlight.dart).
 * FLAG_LAYOUT_IN_SCREEN makes the overlay span the full display including
 * the status-bar area, so display-pixel coordinates land 1:1.
 */
object CopilotOverlay {

    private const val HIGHLIGHT_TIMEOUT_MS = 4_500L

    private val mainHandler = Handler(Looper.getMainLooper())

    private var highlightView: HighlightView? = null
    private var stopPill: TextView? = null
    private var clearRunnable: Runnable? = null

    fun canDraw(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            Settings.canDrawOverlays(context)

    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

    /** Draw (or move) the highlight ring. Main-thread only. */
    fun showHighlight(
        context: Context,
        centerX: Float,
        centerY: Float,
        widthPx: Float,
        heightPx: Float,
        label: String?,
    ) {
        if (!canDraw(context)) return
        val appContext = context.applicationContext
        val wm = appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val view = highlightView ?: HighlightView(appContext).also { created ->
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                overlayType(),
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT,
            )
            try {
                wm.addView(created, params)
                highlightView = created
            } catch (e: Exception) {
                return
            }
        }
        // Pad the ring a little past the element so it reads as a halo, not
        // an outline hiding the control's own edges.
        val pad = 14f
        view.target = RectF(
            centerX - widthPx / 2f - pad,
            centerY - heightPx / 2f - pad,
            centerX + widthPx / 2f + pad,
            centerY + heightPx / 2f + pad,
        )
        view.label = label?.takeIf { it.isNotBlank() }
        view.visibility = View.VISIBLE
        view.startPulse()
        clearRunnable?.let { mainHandler.removeCallbacks(it) }
        val r = Runnable { hideHighlight(appContext) }
        clearRunnable = r
        mainHandler.postDelayed(r, HIGHLIGHT_TIMEOUT_MS)
    }

    fun hideHighlight(context: Context) {
        clearRunnable?.let { mainHandler.removeCallbacks(it) }
        clearRunnable = null
        val view = highlightView ?: return
        view.stopPulse()
        view.visibility = View.GONE
    }

    /** Show the persistent stop pill; [onStop] runs when the user taps it. */
    fun showStopPill(context: Context, onStop: () -> Unit) {
        if (!canDraw(context) || stopPill != null) return
        val appContext = context.applicationContext
        val wm = appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val density = appContext.resources.displayMetrics.density
        val pill = TextView(appContext).apply {
            text = "■  Stop Ayma screen share"
            setTextColor(Color.WHITE)
            textSize = 13f
            setPadding(
                (14 * density).toInt(), (8 * density).toInt(),
                (14 * density).toInt(), (8 * density).toInt(),
            )
            background = ContextCompat.getDrawable(
                appContext, R.drawable.copilot_pill_bg
            )
            setOnClickListener { onStop() }
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = (36 * density).toInt() // below the status bar / cutout
        }
        try {
            wm.addView(pill, params)
            stopPill = pill
        } catch (e: Exception) {
            // No overlay permission (revoked mid-session): the foreground
            // notification still carries a Stop action, so sharing stays
            // stoppable.
        }
    }

    /** Remove every overlay window (ring + pill). Safe from any thread. */
    fun hideAll(context: Context) {
        val appContext = context.applicationContext
        mainHandler.post {
            val wm =
                appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            highlightView?.let {
                it.stopPulse()
                try { wm.removeView(it) } catch (e: Exception) { /* already gone */ }
            }
            highlightView = null
            stopPill?.let {
                try { wm.removeView(it) } catch (e: Exception) { /* already gone */ }
            }
            stopPill = null
        }
    }

    /** The animated ring itself: a breathing rounded-rect stroke + label. */
    private class HighlightView(context: Context) : View(context) {
        var target: RectF? = null
        var label: String? = null

        private var phase = 0f
        private var pulsing = false
        private val pulseRunnable = object : Runnable {
            override fun run() {
                if (!pulsing) return
                phase = (phase + 0.06f) % (2f * Math.PI.toFloat())
                invalidate()
                postDelayed(this, 33L)
            }
        }

        private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = ContextCompat.getColor(context, R.color.ayma_accent)
            strokeWidth = 5f * resources.displayMetrics.density
        }
        private val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = ContextCompat.getColor(context, R.color.ayma_accent)
            alpha = 70
            strokeWidth = 12f * resources.displayMetrics.density
        }
        private val chipPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = ContextCompat.getColor(context, R.color.ayma_accent)
        }
        private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 13f * resources.displayMetrics.density
            typeface = android.graphics.Typeface.DEFAULT_BOLD
        }

        fun startPulse() {
            if (pulsing) return
            pulsing = true
            post(pulseRunnable)
        }

        fun stopPulse() {
            pulsing = false
            removeCallbacks(pulseRunnable)
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val rect = target ?: return
            val density = resources.displayMetrics.density
            val breathe = (Math.sin(phase.toDouble()).toFloat() + 1f) / 2f // 0..1
            val grow = breathe * 5f * density
            val ring = RectF(
                rect.left - grow, rect.top - grow,
                rect.right + grow, rect.bottom + grow,
            )
            val corner = 18f * density
            ringPaint.alpha = 200 + (55 * breathe).toInt()
            canvas.drawRoundRect(ring, corner, corner, glowPaint)
            canvas.drawRoundRect(ring, corner, corner, ringPaint)

            val text = label ?: return
            val textWidth = labelPaint.measureText(text)
            val chipPadX = 10f * density
            val chipPadY = 6f * density
            val chipHeight = labelPaint.textSize + chipPadY * 2
            var chipTop = ring.top - chipHeight - 8f * density
            if (chipTop < 4f * density) chipTop = ring.bottom + 8f * density
            var chipLeft = ring.left
            val maxLeft = width - textWidth - chipPadX * 2 - 4f * density
            if (chipLeft > maxLeft) chipLeft = maxLeft
            if (chipLeft < 4f * density) chipLeft = 4f * density
            val chip = RectF(
                chipLeft, chipTop,
                chipLeft + textWidth + chipPadX * 2, chipTop + chipHeight,
            )
            canvas.drawRoundRect(chip, chipHeight / 2f, chipHeight / 2f, chipPaint)
            canvas.drawText(
                text,
                chipLeft + chipPadX,
                chipTop + chipPadY + labelPaint.textSize * 0.82f,
                labelPaint,
            )
        }
    }
}
