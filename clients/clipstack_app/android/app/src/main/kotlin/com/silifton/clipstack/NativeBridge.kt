package com.silifton.clipstack

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The "clipstack/native" channel (Dart side: lib/src/native.dart). It lives
 * with the app-wide engine, so it works whether or not a screen is open.
 *
 * Events for Dart (shares, pairing links, clipboard reads from the bubble,
 * tile or notification) are queued until Dart asks for them the first time,
 * then pushed as "intentReceived".
 */
class NativeBridge(private val app: Application, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "clipstack/native")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<Map<String, Any?>>()
    private var dartReady = false
    private var activityRef: WeakReference<Activity>? = null

    /** The visible MainActivity, for the few calls that need one. */
    var activity: Activity?
        get() = activityRef?.get()
        set(value) {
            activityRef = value?.let { WeakReference(it) }
        }

    init {
        channel.setMethodCallHandler(::handle)
    }

    /** Hand an event to Dart now, or once it's ready. Any thread. */
    fun deliver(event: Map<String, Any?>) {
        main.post {
            Log.i("ClipStack", "event ${event["kind"]} -> Dart (ready=$dartReady)")
            if (dartReady) channel.invokeMethod("intentReceived", event) else pending.addLast(event)
        }
    }

    /** A share or clipstack://pair link that opened MainActivity. */
    fun deliver(intent: Intent?) {
        describe(intent)?.let { deliver(it) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takeInitialIntent" -> {
                dartReady = true
                result.success(pending.removeFirstOrNull())
                while (pending.isNotEmpty()) channel.invokeMethod("intentReceived", pending.removeFirst())
            }
            "deviceName" -> result.success(deviceName())
            "startKeepAlive" -> {
                runCatching { KeepAliveService.start(app, call.argument<String>("text") ?: "") }
                result.success(null)
            }
            "updateKeepAlive" -> {
                KeepAliveService.update(app, call.argument<String>("text") ?: "")
                result.success(null)
            }
            "stopKeepAlive" -> {
                KeepAliveService.stop(app)
                result.success(null)
            }
            "requestNotificationPermission" -> {
                val activity = activity
                if (activity != null && Build.VERSION.SDK_INT >= 33 &&
                    activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                }
                result.success(null)
            }
            "setClipboardImage" -> {
                val png = call.argument<ByteArray>("png")
                if (png == null) result.error("args", "png missing", null) else {
                    ClipboardWriter.setImage(app, png)
                    result.success(null)
                }
            }
            "pngFromUri" -> {
                val uri = Uri.parse(call.argument<String>("uri") ?: "")
                val maxBytes = call.argument<Int>("maxBytes") ?: (10 * 1024 * 1024)
                // Decoding and PNG-encoding a photo takes seconds: off the main thread.
                worker.execute {
                    val png = runCatching { pngFromUri(uri, maxBytes) }.getOrNull()
                    main.post {
                        if (png == null) result.error("image", "could not read the image", null)
                        else result.success(png)
                    }
                }
            }
            "moveToBack" -> {
                activity?.moveTaskToBack(true)
                result.success(null)
            }
            "showToast" -> {
                Toast.makeText(app, call.argument<String>("text") ?: "", Toast.LENGTH_SHORT).show()
                result.success(null)
            }
            "canDrawOverlays" -> result.success(Settings.canDrawOverlays(app))
            "isPasteServiceEnabled" -> result.success(PasteAccessibilityService.isEnabled(app))
            "openAccessibilitySettings" -> {
                runCatching {
                    (activity ?: app).startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
                result.success(null)
            }
            "requestOverlayPermission" -> {
                val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${app.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                runCatching { (activity ?: app).startActivity(intent) }
                result.success(null)
            }
            "setBubble" -> {
                KeepAliveService.setBubbleEnabled(app, call.argument<Boolean>("enabled") ?: false)
                result.success(null)
            }
            "updateBubble" -> {
                @Suppress("UNCHECKED_CAST")
                val items = (call.argument<List<Map<String, Any?>>>("items") ?: emptyList())
                BubbleController.update(call.argument<String>("status") ?: "", items)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** A share (text or image) or a clipstack://pair link, as a map for Dart. */
    private fun describe(intent: Intent?): Map<String, Any?>? {
        intent ?: return null
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val type = intent.type ?: return null
                if (type.startsWith("image/")) {
                    val uri = streamUri(intent) ?: return null
                    mapOf("kind" to "image", "uri" to uri.toString())
                } else {
                    val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return null
                    mapOf("kind" to "text", "text" to text)
                }
            }
            Intent.ACTION_VIEW -> {
                val data = intent.data ?: return null
                if (data.scheme == "clipstack") mapOf("kind" to "pair", "link" to data.toString()) else null
            }
            else -> null
        }
    }

    @Suppress("DEPRECATION")
    private fun streamUri(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM)

    private fun deviceName(): String =
        Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME)
            ?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    /**
     * Any image → PNG no larger than [maxBytes] (protocol v1 sends PNG only).
     * Large photos are scaled down until they fit.
     */
    private fun pngFromUri(uri: Uri, maxBytes: Int): ByteArray? {
        val bytes = app.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
        var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        var longest = 3000
        while (true) {
            val side = max(bitmap.width, bitmap.height)
            if (side > longest) {
                val scale = longest.toFloat() / side
                bitmap = Bitmap.createScaledBitmap(
                    bitmap, (bitmap.width * scale).roundToInt(), (bitmap.height * scale).roundToInt(), true
                )
            }
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            if (out.size() <= maxBytes || longest < 400) return out.toByteArray().takeIf { out.size() <= maxBytes }
            longest = (max(bitmap.width, bitmap.height) * 0.75f).roundToInt()
        }
    }
}

/** Writing to the clipboard (allowed from the background, unlike reading). */
object ClipboardWriter {
    fun setText(context: Context, text: String) {
        context.getSystemService(ClipboardManager::class.java)
            .setPrimaryClip(ClipData.newPlainText("ClipStack", text))
    }

    /**
     * Writes the PNG to cache/clips and puts a content URI on the clipboard;
     * the clipboard grants readers temporary access through the FileProvider.
     */
    fun setImage(context: Context, png: ByteArray) {
        val dir = File(context.cacheDir, "clips").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() } // only the current clip is needed
        val file = File(dir, "clip-${System.currentTimeMillis()}.png").apply { writeBytes(png) }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.clips", file)
        context.getSystemService(ClipboardManager::class.java)
            .setPrimaryClip(ClipData.newUri(context.contentResolver, "Image", uri))
    }
}
