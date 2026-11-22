package kw.fils.fils

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.service.notification.NotificationListenerService
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** `fils/capture` channel shared by the UI engine and the headless capture engine. */
object CaptureChannels {
    fun register(ctx: Context, messenger: BinaryMessenger, sharedText: () -> String? = { null }): MethodChannel {
        val ch = MethodChannel(messenger, "fils/capture")
        ch.setMethodCallHandler { call, result ->
            val prefs = ctx.getSharedPreferences(FilsNotificationListener.PREFS, Context.MODE_PRIVATE)
            when (call.method) {
                "drainInbox" -> result.success(CaptureInbox.pending(ctx))
                "ack" -> {
                    CaptureInbox.remove(ctx, call.argument<List<String>>("ids") ?: emptyList())
                    result.success(null)
                }
                "inboxCount" -> result.success(CaptureInbox.pending(ctx).size)
                "notificationAccessGranted" ->
                    result.success(NotificationManagerCompat.getEnabledListenerPackages(ctx).contains(ctx.packageName))
                "openNotificationAccessSettings" -> {
                    ctx.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "launchableApps" -> {
                    val pm = ctx.packageManager
                    val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val apps = pm.queryIntentActivities(main, 0)
                        .map { it.activityInfo.packageName to it.loadLabel(pm).toString() }
                        .distinctBy { it.first }
                        .filter { it.first != ctx.packageName && !FilsNotificationListener.isBlocked(it.first) }
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
                "monitoredPackages" -> result.success(FilsNotificationListener.monitored(ctx).toList())
                "setSmsSenders" -> {
                    prefs.edit().putStringSet("sms_senders", (call.argument<List<String>>("senders") ?: emptyList()).map { it.lowercase() }.toSet()).apply()
                    result.success(null)
                }
                "smsCaptureAvailable" -> result.success(BuildConfig.SMS_CAPTURE &&
                    ctx.checkSelfPermission(android.Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED)
                "ignoringBatteryOptimizations" -> {
                    val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(ctx.packageName))
                }
                "openBatterySettings" -> {
                    ctx.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "requestRebind" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        NotificationListenerService.requestRebind(ComponentName(ctx, FilsNotificationListener::class.java))
                    }
                    result.success(null)
                }
                "listenerStatus" -> result.success(mapOf(
                    "connected" to prefs.getBoolean(FilsNotificationListener.KEY_CONNECTED, false),
                    "lastEventAt" to prefs.getLong(FilsNotificationListener.KEY_LAST_EVENT, 0L),
                    "pending" to CaptureInbox.pending(ctx).size,
                    "lastHeadless" to prefs.getString(HeadlessCaptureRunner.KEY_LAST, null),
                ))
                "takeSharedText" -> result.success(sharedText())
                else -> result.notImplemented()
            }
        }
        return ch
    }
}
