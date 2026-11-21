package com.zamansheikh.clipstack_app

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Bridges the Android-only pieces to Dart over the "clipstack/native"
 * channel: share-sheet and pairing-link intents, the keep-alive service,
 * images on the clipboard, and image → PNG conversion.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingIntent: Map<String, Any?>? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "clipstack/native").also {
            it.setMethodCallHandler(::handle)
        }
        pendingIntent = describe(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        describe(intent)?.let { channel?.invokeMethod("intentReceived", it) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takeInitialIntent" -> {
                result.success(pendingIntent)
                pendingIntent = null
            }
            "deviceName" -> result.success(deviceName())
            "startKeepAlive" -> {
                KeepAliveService.start(this, call.argument<String>("text") ?: "")
                result.success(null)
            }
            "updateKeepAlive" -> {
                KeepAliveService.update(this, call.argument<String>("text") ?: "")
                result.success(null)
            }
            "stopKeepAlive" -> {
                KeepAliveService.stop(this)
                result.success(null)
            }
            "requestNotificationPermission" -> {
                if (Build.VERSION.SDK_INT >= 33 &&
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                }
                result.success(null)
            }
            "setClipboardImage" -> {
                val png = call.argument<ByteArray>("png")
                if (png == null) result.error("args", "png missing", null) else {
                    setClipboardImage(png)
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
                        if (png == null) result.error("image", "could not read the shared image", null)
                        else result.success(png)
                    }
                }
            }
            "moveToBack" -> {
                moveTaskToBack(true)
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
        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
            ?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    /**
     * Writes the PNG to cache/clips and puts a content URI on the clipboard.
     * The clipboard grants readers temporary access through the FileProvider.
     */
    private fun setClipboardImage(png: ByteArray) {
        val dir = File(cacheDir, "clips").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() } // only the current clip is needed
        val file = File(dir, "clip-${System.currentTimeMillis()}.png").apply { writeBytes(png) }
        val uri = FileProvider.getUriForFile(this, "$packageName.clips", file)
        val clipboard = getSystemService(ClipboardManager::class.java)
        clipboard.setPrimaryClip(ClipData.newUri(contentResolver, "Image", uri))
    }

    /**
     * Any image the share sheet hands us → PNG no larger than [maxBytes]
     * (protocol v1 sends PNG only). Large photos are scaled down until they fit.
     */
    private fun pngFromUri(uri: Uri, maxBytes: Int): ByteArray? {
        val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
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
