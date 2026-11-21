package com.silifton.clipstack

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * A foreground service that keeps the app process — and the Dart sync
 * connection in the app-wide engine — alive in the background, so a copy on
 * the Mac lands on the phone's clipboard. It also hosts the floating bubble,
 * and its notification has a "Send clipboard" button.
 */
class KeepAliveService : Service() {
    companion object {
        private const val CHANNEL_ID = "sync"
        private const val NOTIFICATION_ID = 1
        private const val EXTRA_TEXT = "text"
        @Volatile private var running = false
        @Volatile private var bubbleEnabled = false
        private var instance: KeepAliveService? = null

        fun start(context: Context, text: String) {
            val intent = Intent(context, KeepAliveService::class.java).putExtra(EXTRA_TEXT, text)
            ContextCompat.startForegroundService(context, intent)
        }

        /**
         * Changes the notification text. Posts directly instead of restarting
         * the service: Android 12+ refuses foreground-service starts from the
         * background.
         */
        fun update(context: Context, text: String) {
            if (!running) return
            context.getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, notification(context, text))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }

        /** Show or hide the bubble (shown only while the service runs). */
        fun setBubbleEnabled(context: Context, enabled: Boolean) {
            bubbleEnabled = enabled
            Handler(Looper.getMainLooper()).post { instance?.syncBubble() }
        }

        private fun notification(context: Context, text: String): android.app.Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Clipboard sync", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Shown while ClipStack keeps your clipboard in sync"
                        setShowBadge(false)
                    }
                )
            }
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val send = PendingIntent.getActivity(
                context, 1, ClipReaderActivity.intent(context),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_clipstack)
                .setContentTitle("ClipStack")
                .setContentText(text.ifBlank { "Keeping your clipboard in sync" })
                .setContentIntent(open)
                .addAction(R.drawable.ic_bubble_send, "Send clipboard", send)
                .setOngoing(true)
                .setSilent(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()
        }
    }

    private var bubble: BubbleController? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = notification(this, intent?.getStringExtra(EXTRA_TEXT) ?: "")
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        running = true
        instance = this
        syncBubble()
        // Not sticky: without the app's Dart side there is nothing to keep alive.
        return START_NOT_STICKY
    }

    private fun syncBubble() {
        val wanted = bubbleEnabled && Settings.canDrawOverlays(this)
        Log.i("ClipStack", "bubble wanted=$wanted (enabled=$bubbleEnabled) showing=${bubble != null}")
        if (wanted && bubble == null) {
            bubble = runCatching { BubbleController(this).also { it.show() } }
                .onFailure { Log.e("ClipStack", "bubble could not be shown", it) }
                .getOrNull()
        } else if (!wanted && bubble != null) {
            bubble?.hide()
            bubble = null
        }
    }

    override fun onDestroy() {
        bubble?.hide()
        bubble = null
        if (instance === this) instance = null
        running = false
        super.onDestroy()
    }
}
