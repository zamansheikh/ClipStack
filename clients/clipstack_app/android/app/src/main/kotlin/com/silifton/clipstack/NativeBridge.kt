package com.silifton.clipstack

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.lang.ref.WeakReference
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

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
            // Received text. Flutter's own Clipboard.setData goes to a plugin that
            // exists only while MainActivity does; with the screen closed and the
            // service still syncing it never answers, and the receive queue stalls.
            "setClipboardText" -> {
                ClipboardWriter.setText(app, call.argument<String>("text") ?: "")
                result.success(null)
            }
            "setClipboardImage" -> {
                val png = call.argument<ByteArray>("png")
                if (png == null) result.error("args", "png missing", null) else {
                    ClipboardWriter.setImage(app, png)
                    result.success(null)
                }
            }
            // The in-app Send button: the app is in front, so the read is allowed.
            "readClipboard" -> result.success(ClipboardReader.read(activity ?: app))
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
            "textFromUri" -> {
                val uri = Uri.parse(call.argument<String>("uri") ?: "")
                val maxBytes = call.argument<Int>("maxBytes") ?: (1024 * 1024)
                worker.execute {
                    val text = runCatching { textFromUri(uri, maxBytes) }
                    main.post {
                        text.fold(
                            onSuccess = { result.success(it) },
                            onFailure = { result.error("text", it.message ?: "could not read the file", null) },
                        )
                    }
                }
            }
            "saveToGallery" -> saveToGallery(call.argument<String>("path"), result)
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

    /** A history picture into the gallery (Pictures/ClipStack), off the main thread. */
    private fun saveToGallery(path: String?, result: MethodChannel.Result) {
        if (path == null) return result.error("args", "path missing", null)
        if (Build.VERSION.SDK_INT < 29 &&
            app.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        ) {
            activity?.requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 2)
            return result.error("permission", "Allow ClipStack to save photos, then tap Save again", null)
        }
        worker.execute {
            val saved = runCatching { GallerySaver.save(app, File(path)) }
            main.post {
                saved.fold(
                    onSuccess = { result.success(null) },
                    onFailure = { result.error("save", "Couldn't save the picture", it.message) },
                )
            }
        }
    }

    /**
     * A share (text, a text file, one picture or several) or a
     * clipstack://pair link, as a map for Dart.
     */
    private fun describe(intent: Intent?): Map<String, Any?>? {
        intent ?: return null
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val type = intent.type ?: return null
                if (type.startsWith("image/")) {
                    val uri = streamUri(intent) ?: return null
                    mapOf("kind" to "image", "uri" to uri.toString())
                } else {
                    // Some apps attach styled text, which getStringExtra misses.
                    val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                    when {
                        !text.isNullOrEmpty() -> mapOf("kind" to "text", "text" to text)
                        // A .txt file or a contact card: Dart reads it off the main thread.
                        else -> streamUri(intent)?.let { mapOf("kind" to "textFile", "uri" to it.toString()) }
                    }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = streamUris(intent)
                if (uris.isEmpty()) null else mapOf("kind" to "images", "uris" to uris.map { it.toString() })
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

    @Suppress("DEPRECATION")
    private fun streamUris(intent: Intent): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM))?.filterNotNull() ?: emptyList()

    /** A shared text file as text, refused if larger than [maxBytes]. */
    private fun textFromUri(uri: Uri, maxBytes: Int): String {
        val bytes = app.contentResolver.openInputStream(uri)?.use { input ->
            val buffer = ByteArray(maxBytes + 1)
            var length = 0
            while (length < buffer.size) {
                val n = input.read(buffer, length, buffer.size - length)
                if (n < 0) break
                length += n
            }
            if (length > maxBytes) throw IOException("The file is too long to send")
            buffer.copyOf(length)
        } ?: throw IOException("Couldn't open the file")
        val text = bytes.toString(Charsets.UTF_8)
        if (text.isBlank()) throw IOException("The file is empty")
        return text
    }

    private fun deviceName(): String =
        Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME)
            ?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    /**
     * Any image → PNG no larger than [maxBytes] (protocol v1 sends PNG only).
     * A PNG that already fits goes as it is: faster, lossless, and the same
     * bytes the other device sent, so its history sees a repeat as one clip.
     * Photos are turned upright (camera JPEGs carry their rotation as EXIF)
     * and scaled down until they fit.
     */
    private fun pngFromUri(uri: Uri, maxBytes: Int): ByteArray? {
        val bytes = app.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
        if (bytes.size <= maxBytes && isDecodablePng(bytes)) return bytes
        var longest = 3000
        // A 50 MP photo would need 200 MB decoded: skip pixels while decoding
        // (powers of two), staying at least [longest] on the long side.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= longest) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
        bitmap = upright(bitmap, bytes)
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
            // PNG size follows the pixel count: aim straight for the limit
            // (with a margin) instead of shrinking a quarter at a time.
            val shrink = min(0.9, sqrt(maxBytes.toDouble() / out.size()) * 0.95)
            longest = (max(bitmap.width, bitmap.height) * shrink).roundToInt()
        }
    }

    /** Applies the photo's EXIF orientation, so it isn't sent sideways. */
    private fun upright(bitmap: Bitmap, bytes: ByteArray): Bitmap {
        val orientation = runCatching {
            ExifInterface(ByteArrayInputStream(bytes))
                .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> matrix.apply { postRotate(90f); postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> matrix.apply { postRotate(270f); postScale(-1f, 1f) }
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    private fun isDecodablePng(bytes: ByteArray): Boolean {
        val signature = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        if (bytes.size < signature.size || !signature.indices.all { bytes[it] == signature[it] }) return false
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        return bounds.outWidth > 0 && bounds.outHeight > 0
    }
}

/**
 * Reading the clipboard. Android 10+ allows it only to the app whose window
 * has focus: MainActivity, or ClipReaderActivity for the bubble and tile.
 */
object ClipboardReader {
    /** {"uri": …} for an image, {"text": …} for text, null when empty. */
    fun read(context: Context): Map<String, Any?>? {
        val clip = context.getSystemService(ClipboardManager::class.java).primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val item = clip.getItemAt(0)
        val uri = item.uri
        if (uri != null && clip.description.hasMimeType("image/*")) return mapOf("uri" to uri.toString())
        val text = item.coerceToText(context)?.toString()
        return if (text.isNullOrBlank()) null else mapOf("text" to text)
    }
}

/** Pictures from history into the phone's gallery, in Pictures/ClipStack. */
object GallerySaver {
    fun save(context: Context, png: File) {
        val name = "ClipStack_${SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())}"
        if (Build.VERSION.SDK_INT >= 29) {
            // MediaStore picks a free name if this one is taken.
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/ClipStack")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
                ?: throw IOException("the gallery refused the picture")
            try {
                val out = resolver.openOutputStream(uri) ?: throw IOException("can't write to the gallery")
                out.use { stream -> png.inputStream().use { it.copyTo(stream) } }
                resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
        } else {
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "ClipStack")
            dir.mkdirs()
            var file = File(dir, "$name.png")
            var n = 1
            while (file.exists()) file = File(dir, "$name (${n++}).png")
            png.copyTo(file)
            MediaScannerConnection.scanFile(context, arrayOf(file.path), arrayOf("image/png"), null)
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
