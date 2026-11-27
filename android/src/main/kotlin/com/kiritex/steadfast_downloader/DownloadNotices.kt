package com.kiritex.steadfast_downloader

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall

/** How a download ended, in the app's own words. */
data class FinishNotice(
    val id: String,
    val title: String,
    val text: String,
    val channelName: String,
    val failed: Boolean,
) {
    companion object {
        fun from(call: MethodCall) = FinishNotice(
            id = call.argument<String>("id") ?: "",
            title = call.argument<String>("title") ?: "",
            text = call.argument<String>("text") ?: "",
            channelName = call.argument<String>("channelName") ?: "",
            failed = call.argument<Boolean>("failed") ?: false,
        )
    }
}

/**
 * The notifications that say a download finished or stopped for good: one
 * per download, on their own channel, a tap opening the app at that download.
 */
object DownloadNotices {
    private const val TAG = "SteadfastDownloader"
    // The package's first name, kept so installs keep their notification settings.
    private const val CHANNEL_ID = "durable_downloads_finished"

    // One per download: the download's id is the tag, so this never meets
    // the foreground service's own notification.
    private const val NOTIFICATION_ID = 0x0D0E

    /** A tap opens the app with this action and the download's id. */
    const val ACTION_OPEN_DOWNLOAD = "com.kiritex.steadfast_downloader.OPEN_DOWNLOAD"
    const val EXTRA_ID = "com.kiritex.steadfast_downloader.DOWNLOAD_ID"

    /** Whether the app may notify: Android 13+'s permission, and the switch
     * the person can turn off in the system's settings. */
    fun allowed(context: Context): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == PackageManager.PERMISSION_GRANTED)

    fun show(context: Context, notice: FinishNotice) {
        if (notice.id.isEmpty() || !allowed(context)) return
        ensureChannel(context, notice.channelName)
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(
                if (notice.failed) {
                    android.R.drawable.stat_notify_error
                } else {
                    android.R.drawable.stat_sys_download_done
                },
            )
            .setContentTitle(notice.title)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
        if (notice.text.isNotEmpty()) builder.setContentText(notice.text)
        openDownload(context, notice.id)?.let { builder.setContentIntent(it) }
        try {
            NotificationManagerCompat.from(context)
                .notify(notice.id, NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            // The permission went between the check and here.
            Log.w(TAG, "not shown: $e")
        }
    }

    /** Created once; its name follows the app's language. */
    private fun ensureChannel(context: Context, name: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                name.ifEmpty { "Finished downloads" },
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
    }

    private fun openDownload(context: Context, id: String): PendingIntent? {
        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName) ?: return null
        launch.action = ACTION_OPEN_DOWNLOAD
        launch.putExtra(EXTRA_ID, id)
        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        // Its own request code per download, so each keeps its own id.
        return PendingIntent.getActivity(
            context,
            id.hashCode(),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
