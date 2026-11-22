package kw.fils.fils

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.service.notification.NotificationListenerService
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var sharedText: String? = null
    private var sink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        captureShare(intent)
    }

    private fun captureShare(i: Intent?) {
        if (i?.action == Intent.ACTION_SEND && i.type == "text/plain") {
            sharedText = i.getStringExtra(Intent.EXTRA_TEXT)?.take(4000)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "fils/capture/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                CaptureInbox.listener = { runOnUiThread { sink?.success(true) } }
            }
            override fun onCancel(arguments: Any?) {
                sink = null
                CaptureInbox.listener = null
            }
        })
        MethodChannel(messenger, "fils/capture").setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences(FilsNotificationListener.PREFS, MODE_PRIVATE)
            when (call.method) {
                "drainInbox" -> result.success(CaptureInbox.pending(this))
                "ack" -> {
                    CaptureInbox.remove(this, call.argument<List<String>>("ids") ?: emptyList())
                    result.success(null)
                }
                "notificationAccessGranted" ->
                    result.success(NotificationManagerCompat.getEnabledListenerPackages(this).contains(packageName))
                "openNotificationAccessSettings" -> {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "launchableApps" -> {
                    val pm = packageManager
                    val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val apps = pm.queryIntentActivities(main, 0)
                        .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
                        .distinctBy { it.first }
                        .filter { it.first != packageName && !FilsNotificationListener.isBlocked(it.first) }
                        .sortedBy { it.second.lowercase() }
                        .map { mapOf("package" to it.first, "label" to it.second) }
                    result.success(apps)
                }
                "setMonitoredPackages" -> {
                    val pkgs = (call.argument<List<String>>("packages") ?: emptyList())
                        .filterNot { FilsNotificationListener.isBlocked(it) }.toSet()
                    prefs.edit().putStringSet(FilsNotificationListener.KEY_PACKAGES, pkgs).apply()
                    result.success(null)
                }
                "monitoredPackages" -> result.success(FilsNotificationListener.monitored(this).toList())
                "setSmsSenders" -> {
                    prefs.edit().putStringSet("sms_senders", (call.argument<List<String>>("senders") ?: emptyList()).map { it.lowercase() }.toSet()).apply()
                    result.success(null)
                }
                "smsCaptureAvailable" -> result.success(BuildConfig.SMS_CAPTURE &&
                    checkSelfPermission(android.Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED)
                "ignoringBatteryOptimizations" -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "openBatterySettings" -> {
                    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "requestRebind" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        NotificationListenerService.requestRebind(ComponentName(this, FilsNotificationListener::class.java))
                    }
                    result.success(null)
                }
                "listenerStatus" -> result.success(mapOf(
                    "connected" to prefs.getBoolean(FilsNotificationListener.KEY_CONNECTED, false),
                    "lastEventAt" to prefs.getLong(FilsNotificationListener.KEY_LAST_EVENT, 0L),
                    "pending" to CaptureInbox.pending(this).size,
                ))
                "takeSharedText" -> {
                    result.success(sharedText)
                    sharedText = null
                }
                else -> result.notImplemented()
            }
        }
    }
}
