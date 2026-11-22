package kw.fils.fils

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

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
        CaptureChannels.register(this, messenger) { sharedText.also { sharedText = null } }
    }
}
