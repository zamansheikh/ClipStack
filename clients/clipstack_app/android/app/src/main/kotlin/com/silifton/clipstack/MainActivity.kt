package com.silifton.clipstack

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/**
 * The app's screen. It attaches to the process-wide engine owned by
 * [ClipStackApplication] and leaves it running when closed, so sync keeps
 * going after the app is swiped away.
 */
class MainActivity : FlutterActivity() {
    private val bridge: NativeBridge
        get() = (application as ClipStackApplication).bridge

    override fun getCachedEngineId(): String = ClipStackApplication.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bridge.activity = this
        // Re-created (rotation, theme change): that share was already handled.
        if (savedInstanceState == null) bridge.deliver(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        bridge.deliver(intent)
    }

    override fun onResume() {
        super.onResume()
        bridge.activity = this
    }

    override fun onDestroy() {
        if (bridge.activity === this) bridge.activity = null
        super.onDestroy()
    }
}
