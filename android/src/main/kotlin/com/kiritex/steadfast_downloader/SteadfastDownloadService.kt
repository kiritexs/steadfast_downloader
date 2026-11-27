package com.kiritex.steadfast_downloader

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall

/** What the notification shows, in the app's own words. */
data class Notice(
    val title: String,
    val text: String,
    val progress: Double?,
    val channelName: String,
) {
    companion object {
        val EMPTY = Notice("", "", null, "")

        fun from(call: MethodCall) = Notice(
            title = call.argument<String>("title") ?: "",
            text = call.argument<String>("text") ?: "",
            progress = call.argument<Double>("progress"),
            channelName = call.argument<String>("channelName") ?: "",
        )
    }
}

/**
 * Keeps the app's process downloading while it isn't in front: a foreground
 * service of the dataSync type showing the download notification, and a
 * partial wake lock while it runs. It downloads nothing itself; Dart does, in
 * this process.
 */
class SteadfastDownloadService : Service() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // First thing: Android stops an app whose service doesn't in time.
        try {
            ensureChannel(this, current.channelName)
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                build(this, current),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                } else {
                    0
                },
            )
        } catch (e: Exception) {
            // Android 12+ refuses one started while the app isn't in front;
            // reported, never a crash. Downloads go on unprotected.
            Log.w(TAG, "foreground refused: $e")
            stopSelf()
            report(EVENT_REFUSED)
            return START_NOT_STICKY
        }
        running = true
        holdWakeLock(this)
        report(EVENT_HELD)
        // Killed, it isn't started again: Dart, which downloads, went too.
        return START_NOT_STICKY
    }

    /** Android 15+: dataSync's 6 hours a day are used up; stop now. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "foreground time is up")
        report(EVENT_TIMED_OUT)
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "SteadfastDownloader"
        private const val NOTIFICATION_ID = 0x0D0D
        // The package's first name, kept so installs keep their notification settings.
        private const val CHANNEL_ID = "durable_downloads"
        private const val PROGRESS_MAX = 1000
        private const val WAKE_LOCK_TAG = "steadfast_downloader:downloads"

        // Renewed with every update: one nothing renews (no progress) lapses.
        private const val WAKE_LOCK_MS = 30 * 60 * 1000L

        /** A tap on the notification opens the app with this action. */
        const val ACTION_OPEN = "com.kiritex.steadfast_downloader.OPEN"

        const val EVENT_HELD = "held"
        const val EVENT_REFUSED = "refused"
        const val EVENT_TIMED_OUT = "timedOut"

        /** The plugin, told of each event on the main thread. */
        var listener: ((String) -> Unit)? = null

        private var current = Notice.EMPTY
        private var running = false
        private var wakeLock: PowerManager.WakeLock? = null

        /** False when Android refused to start it (the app isn't in front). */
        fun start(context: Context, notice: Notice): Boolean {
            current = notice
            return try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, SteadfastDownloadService::class.java),
                )
                true
            } catch (e: Exception) {
                Log.w(TAG, "not started: $e")
                false
            }
        }

        fun update(context: Context, notice: Notice) {
            current = notice
            if (!running) return
            holdWakeLock(context)
            if (!canNotify(context)) return
            ensureChannel(context, notice.channelName)
            NotificationManagerCompat.from(context)
                .notify(NOTIFICATION_ID, build(context, notice))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SteadfastDownloadService::class.java))
        }

        private fun report(event: String) {
            listener?.invoke(event)
        }

        private fun canNotify(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == PackageManager.PERMISSION_GRANTED

        /** Created once; its name follows the app's language. */
        private fun ensureChannel(context: Context, name: String) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            val channel = NotificationChannel(
                CHANNEL_ID,
                name.ifEmpty { "Downloads" },
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }

        private fun build(context: Context, notice: Notice): Notification {
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(notice.title)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setShowWhen(false)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setForegroundServiceBehavior(
                    NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE,
                )
            if (notice.text.isNotEmpty()) builder.setContentText(notice.text)
            notice.progress?.let {
                builder.setProgress(
                    PROGRESS_MAX,
                    (it.coerceIn(0.0, 1.0) * PROGRESS_MAX).toInt(),
                    false,
                )
            }
            openApp(context)?.let { builder.setContentIntent(it) }
            return builder.build()
        }

        private fun openApp(context: Context): PendingIntent? {
            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName) ?: return null
            // Its own action, so a running app gets it as a new intent rather
            // than only being brought forward.
            launch.action = ACTION_OPEN
            launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return PendingIntent.getActivity(
                context,
                0,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun holdWakeLock(context: Context) {
            val lock = wakeLock ?: (context.applicationContext
                .getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
                .also {
                    it.setReferenceCounted(false)
                    wakeLock = it
                }
            lock.acquire(WAKE_LOCK_MS)
        }

        private fun releaseWakeLock() {
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
        }
    }
}
