package com.silifton.clipstack

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast

/**
 * An invisible screen that reads the clipboard and sends it to paired
 * devices. Android 10+ only lets the app with window focus read the
 * clipboard, so the bubble, the Quick Settings tile and the notification
 * action open this for a moment instead of reading it themselves.
 */
class ClipReaderActivity : Activity() {
    private var done = false
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Focus normally arrives within a frame or two; don't linger if not.
        main.postDelayed({ if (!done) finish() }, 2000)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        val event = ClipboardReader.read(this)?.plus("kind" to "clipboard")
        Log.i("ClipStack", "clipboard read: ${event?.get("uri")?.let { "image" } ?: event?.get("text")?.let { "text, ${(it as String).length} chars" } ?: "empty"}") // never the content
        if (event == null) {
            Toast.makeText(this, "The clipboard is empty", Toast.LENGTH_SHORT).show()
        } else {
            (application as ClipStackApplication).bridge.deliver(event)
        }
        finish()
    }

    override fun finish() {
        super.finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    companion object {
        fun intent(context: Context): Intent =
            Intent(context, ClipReaderActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
    }
}
