package kw.fils.fils

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * Processes queued captures when no UI engine is attached, by running the Dart
 * `captureMain` entrypoint in a headless FlutterEngine. It uses the same encrypted database
 * (key from Keystore-backed storage), the same migrations and the same idempotent pipeline.
 * Only one engine runs at a time; events arriving meanwhile are drained by that run or the
 * next one.
 */
object HeadlessCaptureRunner {
    const val KEY_LAST = "last_headless_summary"
    private var engine: FlutterEngine? = null
    private var rerun = false
    private val main = Handler(Looper.getMainLooper())

    fun request(ctx: Context) = main.post { start(ctx.applicationContext) }

    private fun start(ctx: Context) {
        if (CaptureInbox.listener != null) { // UI engine alive: it drains itself
            CaptureInbox.listener?.invoke()
            return
        }
        if (engine != null) { rerun = true; return }
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(ctx)
            loader.ensureInitializationComplete(ctx, null)
            val e = FlutterEngine(ctx) // registers plugins automatically
            CaptureChannels.register(ctx, e.dartExecutor.binaryMessenger)
            MethodChannel(e.dartExecutor.binaryMessenger, "fils/capture/headless").setMethodCallHandler { call, result ->
                result.success(null)
                if (call.method == "done") {
                    val args = (call.arguments as? Map<*, *>) ?: emptyMap<String, Any>()
                    ctx.getSharedPreferences(FilsNotificationListener.PREFS, Context.MODE_PRIVATE).edit()
                        .putString(KEY_LAST, JSONObject(args.mapKeys { it.key.toString() }).put("at", System.currentTimeMillis()).toString())
                        .apply()
                    finish(ctx)
                }
            }
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "package:fils/capture_main.dart", "captureMain"),
            )
            engine = e
            main.postDelayed({ if (engine === e) finish(ctx) }, 30_000) // hard stop
        } catch (t: Throwable) {
            engine = null // items stay queued for the next app open
        }
    }

    private fun finish(ctx: Context) {
        engine?.destroy()
        engine = null
        if (rerun) {
            rerun = false
            start(ctx)
        }
    }
}
