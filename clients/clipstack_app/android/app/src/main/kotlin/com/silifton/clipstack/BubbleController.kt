package com.silifton.clipstack

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.Toast
import java.io.File
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The floating ClipStack bubble, drawn over other apps ("Display over other
 * apps" permission), Messenger chat-head style:
 *  - drag it anywhere; let go and it snaps to the nearest edge;
 *  - drag it onto the ✕ that appears at the bottom to dismiss it;
 *  - tap it and Send, Paste and Settings (icons only) fan out evenly around it.
 * A dot shows whether sync is connected. Hosted by [KeepAliveService], so it
 * exists exactly while sync is running.
 */
class BubbleController(private val context: Context) {
    private val wm = context.getSystemService(WindowManager::class.java)
    private val prefs = context.getSharedPreferences("bubble", Context.MODE_PRIVATE)
    private val density = context.resources.displayMetrics.density
    private val main = Handler(Looper.getMainLooper())
    private val bridge get() = (context.applicationContext as ClipStackApplication).bridge

    private val circleSize = dp(48)
    private val windowSize = circleSize + dp(12) // room for the shadow
    private lateinit var circle: FrameLayout
    private lateinit var statusDot: View
    private val root: FrameLayout = buildBubble()
    private val params = overlayParams(windowSize, windowSize).apply {
        x = prefs.getInt("x", screenWidth() - windowSize)
        y = prefs.getInt("y", dp(260))
    }

    // The dismiss target. Added before the bubble so the bubble draws above it.
    private val targetSize = dp(64)
    private val targetWindow = dp(150)
    private lateinit var targetCircle: FrameLayout
    private val target: FrameLayout = buildTarget()
    private val targetParams = overlayParams(targetWindow, targetWindow).apply {
        flags = flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        x = (screenWidth() - targetWindow) / 2
        y = screenHeight() - targetWindow - dp(36)
    }

    private var menu: View? = null
    private var shown = false

    fun show() {
        if (shown) return
        wm.addView(target, targetParams)
        wm.addView(root, params)
        shown = true
        current = this
        showStatus()
    }

    fun hide() {
        closeMenu()
        if (shown) {
            runCatching { wm.removeView(root) }
            runCatching { wm.removeView(target) }
        }
        shown = false
        if (current === this) current = null
    }

    // MARK: - Bubble

    private fun buildBubble(): FrameLayout {
        circle = FrameLayout(context).apply {
            background = brandCircle()
            elevation = dp(5).toFloat()
            addView(glyph(R.drawable.ic_stat_clipstack, Color.WHITE, dp(13)))
            contentDescription = "ClipStack"
        }
        statusDot = View(context).apply {
            elevation = dp(6).toFloat()
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setStroke(dp(2), Color.WHITE)
            }
        }
        return FrameLayout(context).apply {
            addView(circle, FrameLayout.LayoutParams(circleSize, circleSize, Gravity.CENTER))
            addView(statusDot, FrameLayout.LayoutParams(dp(12), dp(12), Gravity.TOP or Gravity.END).apply {
                setMargins(0, dp(6), dp(6), 0)
            })
            setOnTouchListener(DragListener())
        }
    }

    private fun showStatus() {
        (statusDot.background as GradientDrawable).setColor(if (connected) 0xFF34C759.toInt() else 0xFFFF9F0A.toInt())
    }

    @SuppressLint("ClickableViewAccessibility")
    private inner class DragListener : View.OnTouchListener {
        private val slop = ViewConfiguration.get(context).scaledTouchSlop
        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var dragging = false
        private var overTarget = false

        override fun onTouch(view: View, event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = params.y
                    dragging = false
                    overTarget = false
                    circle.animate().scaleX(0.9f).scaleY(0.9f).setDuration(90).start()
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    if (!dragging && hypot(dx, dy) > slop) {
                        dragging = true
                        showTarget(true)
                    }
                    if (dragging) {
                        // Near the ✕ the bubble snaps onto it, like a magnet.
                        val near = hypot(event.rawX - targetCenterX(), event.rawY - targetCenterY()) < dp(96)
                        if (near) {
                            params.x = (targetCenterX() - windowSize / 2f).roundToInt()
                            params.y = (targetCenterY() - windowSize / 2f).roundToInt()
                        } else {
                            params.x = (startX + dx).roundToInt()
                            params.y = (startY + dy).roundToInt()
                        }
                        if (near != overTarget) {
                            overTarget = near
                            root.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                            targetCircle.animate().scaleX(if (near) 1.25f else 1f).scaleY(if (near) 1.25f else 1f)
                                .setDuration(140).start()
                        }
                        wm.updateViewLayout(root, params)
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    circle.animate().scaleX(1f).scaleY(1f).setDuration(120).start()
                    when {
                        dragging && overTarget -> dismiss()
                        dragging -> {
                            showTarget(false)
                            snapToEdge()
                        }
                        event.actionMasked == MotionEvent.ACTION_UP -> openMenu()
                    }
                }
            }
            return true
        }
    }

    private val onLeft get() = params.x + windowSize / 2 < screenWidth() / 2

    private fun snapToEdge() {
        val targetX = if (onLeft) 0 else screenWidth() - windowSize
        // Keep room above and below for the buttons that fan out.
        params.y = params.y.coerceIn(dp(120), screenHeight() - windowSize - dp(150))
        ValueAnimator.ofInt(params.x, targetX).apply {
            duration = 220
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                params.x = it.animatedValue as Int
                if (shown) wm.updateViewLayout(root, params)
            }
            start()
        }
        prefs.edit().putInt("x", targetX).putInt("y", params.y).apply()
    }

    // MARK: - Drag to dismiss

    private fun buildTarget(): FrameLayout {
        targetCircle = FrameLayout(context).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0xE61F1E2A.toInt())
                setStroke(dp(2), 0x59FFFFFF)
            }
            elevation = dp(4).toFloat()
            addView(glyph(R.drawable.ic_bubble_close, Color.WHITE, dp(19)))
        }
        return FrameLayout(context).apply {
            addView(targetCircle, FrameLayout.LayoutParams(targetSize, targetSize, Gravity.CENTER))
            alpha = 0f
            visibility = View.INVISIBLE
        }
    }

    private fun targetCenterX() = targetParams.x + targetWindow / 2f
    private fun targetCenterY() = targetParams.y + targetWindow / 2f

    private fun showTarget(visible: Boolean) {
        target.animate().cancel()
        if (visible) {
            target.visibility = View.VISIBLE
            target.translationY = dp(40).toFloat()
            target.animate().alpha(1f).translationY(0f).setDuration(180).setInterpolator(DecelerateInterpolator()).start()
        } else {
            targetCircle.scaleX = 1f
            targetCircle.scaleY = 1f
            target.animate().alpha(0f).translationY(dp(40).toFloat()).setDuration(150)
                .withEndAction { target.visibility = View.INVISIBLE }.start()
        }
    }

    private fun dismiss() {
        root.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        circle.animate().scaleX(0f).scaleY(0f).alpha(0f).setDuration(180).withEndAction {
            KeepAliveService.setBubbleEnabled(context, false) // removes both windows
            bridge.deliver(mapOf("kind" to "bubbleHidden"))
            toast("Bubble hidden. Turn it back on in ClipStack settings.")
        }.start()
        targetCircle.animate().scaleX(0.6f).scaleY(0.6f).alpha(0f).setDuration(180).start()
    }

    // MARK: - Menu: Send, Paste, Settings around the bubble

    private enum class Action(val label: String, val icon: Int) {
        SEND("Send", R.drawable.ic_bubble_send),
        PASTE("Paste", R.drawable.ic_bubble_paste),
        SETTINGS("Settings", R.drawable.ic_bubble_settings),
    }

    private fun openMenu() {
        if (menu != null) return
        val p = Palette(isDark())
        val cx = params.x + windowSize / 2f
        val cy = params.y + windowSize / 2f
        val inward = if (onLeft) 1 else -1 // toward the middle of the screen
        val radius = dp(82).toFloat()
        val button = dp(50)

        val overlay = FrameLayout(context).apply {
            setBackgroundColor(0x66000000) // dim the app behind while the menu is open
            setOnClickListener { closeMenu() }
        }
        // The bubble itself turns into a close button, exactly in place.
        overlay.addView(FrameLayout(context).apply {
            background = brandCircle()
            elevation = dp(5).toFloat()
            addView(glyph(R.drawable.ic_bubble_close, Color.WHITE, dp(14)))
            setOnClickListener { closeMenu() }
        }, FrameLayout.LayoutParams(circleSize, circleSize).apply {
            leftMargin = (cx - circleSize / 2f).roundToInt()
            topMargin = (cy - circleSize / 2f).roundToInt()
        })

        Action.entries.forEachIndexed { index, action ->
            // Evenly spaced on a circle around the bubble: 60° apart, on the
            // side facing the middle of the screen.
            val angle = Math.toRadians(listOf(-60.0, 0.0, 60.0)[index])
            val ux = inward * cos(angle).toFloat()
            val uy = sin(angle).toFloat()
            val bx = cx + radius * ux
            val by = cy + radius * uy

            val buttonView = FrameLayout(context).apply {
                background = if (action == Action.SEND) brandCircle()
                else GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(p.surface)
                }
                elevation = dp(6).toFloat()
                addView(glyph(action.icon, if (action == Action.SEND) Color.WHITE else p.accent, dp(13)))
                contentDescription = action.label
                setOnClickListener { run(action) }
            }
            overlay.addView(buttonView, FrameLayout.LayoutParams(button, button).apply {
                leftMargin = (bx - button / 2f).roundToInt()
                topMargin = (by - button / 2f).roundToInt()
            })

            // Spring out from the bubble, slightly staggered.
            buttonView.let { view ->
                view.alpha = 0f
                view.scaleX = 0.3f
                view.scaleY = 0.3f
                view.translationX = cx - bx
                view.translationY = cy - by
                view.animate().alpha(1f).scaleX(1f).scaleY(1f).translationX(0f).translationY(0f)
                    .setStartDelay(index * 40L).setDuration(260).setInterpolator(OvershootInterpolator(1.3f)).start()
            }
        }

        wm.addView(overlay, fullScreenParams())
        overlay.alpha = 0f
        overlay.animate().alpha(1f).setDuration(140).start()
        root.visibility = View.INVISIBLE // the close button stands in while the menu is open
        menu = overlay
    }

    private fun closeMenu() {
        menu?.let { runCatching { wm.removeView(it) } }
        menu = null
        root.visibility = View.VISIBLE
    }

    private fun run(action: Action) {
        closeMenu()
        when (action) {
            Action.SEND -> context.startActivity(ClipReaderActivity.intent(context))
            Action.PASTE -> paste()
            Action.SETTINGS -> {
                context.startActivity(
                    Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                bridge.deliver(mapOf("kind" to "openSettings"))
            }
        }
    }

    /**
     * Pastes the clipboard (which already holds your latest Mac copy) into
     * the field you're typing in. Only an Accessibility service can do that
     * on Android; without it, Paste puts the newest clip on the clipboard so
     * a long-press pastes it.
     */
    private fun paste() {
        val service = PasteAccessibilityService.instance
        if (service == null) {
            copyNewest()
            return
        }
        // Let the menu window go first, so the app's field is the paste target.
        main.postDelayed({
            if (!service.pasteIntoFocusedField()) toast("Tap a text field first, then Paste")
        }, 150)
    }

    /** The newest clip in history back on the clipboard, ready to paste by hand. */
    private fun copyNewest() {
        val item = items.firstOrNull()
        if (item == null) {
            toast("Nothing to paste yet")
            return
        }
        val imagePath = item["imagePath"] as? String
        if (imagePath != null) {
            runCatching { ClipboardWriter.setImage(context, File(imagePath).readBytes()) }
        } else {
            val text = item["text"] as? String ?: return
            ClipboardWriter.setText(context, text)
            // So opening the app doesn't send it straight back.
            bridge.deliver(mapOf("kind" to "copied", "text" to text))
        }
        toast("Copied. Long-press any text field to paste.")
    }

    // MARK: - Helpers

    private fun brandCircle() = GradientDrawable(
        GradientDrawable.Orientation.TL_BR,
        intArrayOf(0xFF7FA6F6.toInt(), 0xFF7B80F2.toInt(), 0xFF9763EC.toInt()),
    ).apply { shape = GradientDrawable.OVAL }

    private fun glyph(icon: Int, tint: Int, padding: Int) = ImageView(context).apply {
        setImageResource(icon)
        setColorFilter(tint)
        scaleType = ImageView.ScaleType.FIT_CENTER
        setPadding(padding, padding, padding, padding)
        layoutParams = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
    }

    private fun toast(text: String) = Toast.makeText(context, text, Toast.LENGTH_SHORT).show()

    private fun overlayParams(width: Int, height: Int) = WindowManager.LayoutParams(
        width,
        height,
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        if (Build.VERSION.SDK_INT >= 28) {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    /** Whole-screen window for the menu, in the same coordinates as the bubble. */
    private fun fullScreenParams() = overlayParams(
        WindowManager.LayoutParams.MATCH_PARENT,
        WindowManager.LayoutParams.MATCH_PARENT,
    ).apply {
        flags = flags or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
    }

    private fun isDark() =
        (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    private fun screenWidth(): Int =
        if (Build.VERSION.SDK_INT >= 30) wm.currentWindowMetrics.bounds.width()
        else context.resources.displayMetrics.widthPixels

    private fun screenHeight(): Int =
        if (Build.VERSION.SDK_INT >= 30) wm.currentWindowMetrics.bounds.height()
        else context.resources.displayMetrics.heightPixels

    private fun dp(value: Int) = (value * density).roundToInt()

    /** Colours matching the app's light and dark themes. */
    private class Palette(dark: Boolean) {
        val surface = if (dark) 0xFF2A2938.toInt() else 0xFFFFFFFF.toInt()
        val accent = if (dark) 0xFFB3A8FF.toInt() else 0xFF6E5BEA.toInt()
    }

    companion object {
        /** Pushed from Dart: connection (the status dot) and newest clips (Paste fallback). */
        private var connected = false
        private var items: List<Map<String, Any?>> = emptyList()
        private var current: BubbleController? = null

        fun update(status: String, items: List<Map<String, Any?>>) {
            connected = status.startsWith("Connected")
            this.items = items.take(5)
            current?.showStatus()
        }
    }
}
