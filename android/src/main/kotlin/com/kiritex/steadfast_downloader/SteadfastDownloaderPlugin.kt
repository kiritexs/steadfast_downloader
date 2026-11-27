package com.kiritex.steadfast_downloader

import android.Manifest
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The plugin's two channels on Android. The keep-alive's: hold starts the
 * foreground service and answers once it is in the foreground or was refused;
 * update re-words its notification; release stops it. A tap on the
 * notification and Android 15's time limit come back as events. The
 * notifications': the permission, asked for on Android 13+; a download's
 * finish shown; a tap on one sent back with its download, kept until Dart asks
 * for it (launchTap) when it came before Dart could hear it.
 */
class SteadfastDownloaderPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener,
    PluginRegistry.RequestPermissionsResultListener {

    private var channel: MethodChannel? = null
    private var notices: MethodChannel? = null
    private var context: Context? = null
    private var activity: ActivityPluginBinding? = null
    private val main = Handler(Looper.getMainLooper())
    private val waiting = mutableListOf<MethodChannel.Result>()
    private val asking = mutableListOf<MethodChannel.Result>()

    // A tap that launched the app comes before Dart runs, and a message to
    // Dart then is dropped: kept until Dart asks (launchTap), sent after.
    private var pendingTap: String? = null
    private var dartListens = false
    private val onService: (String) -> Unit = { event -> onServiceEvent(event) }
    private val notInTime = Runnable { answerHolds(SteadfastDownloadService.EVENT_REFUSED) }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        notices = MethodChannel(binding.binaryMessenger, NOTICES_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        SteadfastDownloadService.listener = onService
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // The engine, which downloads, is going (the app was swiped away):
        // the service has nothing left to keep. The .part covers the next
        // launch.
        context?.let { SteadfastDownloadService.stop(it) }
        if (SteadfastDownloadService.listener === onService) {
            SteadfastDownloadService.listener = null
        }
        answerHolds(SteadfastDownloadService.EVENT_REFUSED)
        answerAsks()
        channel?.setMethodCallHandler(null)
        channel = null
        notices?.setMethodCallHandler(null)
        notices = null
        context = null
        dartListens = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = context ?: return result.success(null)
        when (call.method) {
            "hold" -> hold(context, Notice.from(call), result)
            "update" -> {
                SteadfastDownloadService.update(context, Notice.from(call))
                result.success(null)
            }
            "release" -> {
                SteadfastDownloadService.stop(context)
                result.success(null)
            }
            "permission" -> permission(context, call.argument<Boolean>("ask") ?: true, result)
            "show" -> {
                DownloadNotices.show(context, FinishNotice.from(call))
                result.success(null)
            }
            "launchTap" -> {
                dartListens = true
                result.success(pendingTap)
                pendingTap = null
            }
            else -> result.notImplemented()
        }
    }

    /** Android 13+ asks once the app is in front; before that it's the
     * system settings' switch alone. */
    private fun permission(context: Context, ask: Boolean, result: MethodChannel.Result) {
        val activity = activity?.activity
        if (DownloadNotices.allowed(context) ||
            !ask ||
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            activity == null
        ) {
            return result.success(DownloadNotices.allowed(context))
        }
        asking += result
        if (asking.size > 1) return
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        answerAsks()
        return true
    }

    private fun answerAsks() {
        val allowed = context?.let { DownloadNotices.allowed(it) } ?: false
        val results = asking.toList()
        asking.clear()
        results.forEach { it.success(allowed) }
    }

    private fun hold(context: Context, notice: Notice, result: MethodChannel.Result) {
        if (!SteadfastDownloadService.start(context, notice)) {
            return result.success(SteadfastDownloadService.EVENT_REFUSED)
        }
        // Answered once the service is in the foreground, or wasn't in time.
        waiting += result
        main.removeCallbacks(notInTime)
        main.postDelayed(notInTime, START_TIMEOUT_MS)
    }

    private fun onServiceEvent(event: String) {
        when (event) {
            SteadfastDownloadService.EVENT_HELD,
            SteadfastDownloadService.EVENT_REFUSED -> answerHolds(event)
            SteadfastDownloadService.EVENT_TIMED_OUT ->
                channel?.invokeMethod("timedOut", null)
        }
    }

    private fun answerHolds(answer: String) {
        main.removeCallbacks(notInTime)
        val results = waiting.toList()
        waiting.clear()
        results.forEach { it.success(answer) }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addOnNewIntentListener(this)
        binding.addRequestPermissionsResultListener(this)
        // The app opened from a finish notification.
        tappedNotice(binding.activity.intent)
    }

    /** A rotation: the permission dialog stays up, and its answer comes to
     * the new activity, so the asks wait for it instead of hearing "no". */
    override fun onDetachedFromActivityForConfigChanges() {
        activity?.removeOnNewIntentListener(this)
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeOnNewIntentListener(this)
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
        answerAsks()
    }

    /** A notification was tapped while the app was running. */
    override fun onNewIntent(intent: Intent): Boolean {
        if (tappedNotice(intent)) return false
        if (intent.action != SteadfastDownloadService.ACTION_OPEN) return false
        channel?.invokeMethod("tapped", null)
        return false
    }

    /** A finish notification's tap, sent once: its id is taken off the
     * intent, which the activity keeps across a rotation. */
    private fun tappedNotice(intent: Intent?): Boolean {
        if (intent?.action != DownloadNotices.ACTION_OPEN_DOWNLOAD) return false
        val id = intent.getStringExtra(DownloadNotices.EXTRA_ID) ?: return true
        intent.removeExtra(DownloadNotices.EXTRA_ID)
        if (dartListens) {
            notices?.invokeMethod("tapped", mapOf("id" to id))
        } else {
            pendingTap = id
        }
        return true
    }

    private companion object {
        const val CHANNEL = "steadfast_downloader/keep_alive"
        const val NOTICES_CHANNEL = "steadfast_downloader/notifications"
        const val START_TIMEOUT_MS = 5000L
        const val PERMISSION_REQUEST = 0x0D0E
    }
}
