package com.silifton.clipstack

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Starts one Flutter engine for the whole process and keeps it cached.
 *
 * The sync connection lives in Dart. Owning the engine here (instead of in
 * MainActivity) keeps it running while the foreground service keeps the
 * process alive — after the app is swiped away, and for the bubble, the Quick
 * Settings tile and the notification action, none of which open the app.
 */
class ClipStackApplication : Application() {
    lateinit var bridge: NativeBridge
        private set

    override fun onCreate() {
        super.onCreate()
        val engine = FlutterEngine(this) // registers plugins
        bridge = NativeBridge(this, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    companion object {
        const val ENGINE_ID = "clipstack"
    }
}
