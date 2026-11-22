package kw.fils.fils

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.util.UUID

/**
 * Durable app-private capture inbox (one JSON file per event, written atomically).
 * App-private storage is sandboxed and protected by Android file-based encryption.
 * Parsing, dedupe and persistence happen in Dart; native code only filters and queues.
 */
object CaptureInbox {
    private const val MAX_EVENTS = 500
    private const val MAX_TEXT = 2000
    @Volatile var listener: (() -> Unit)? = null

    private fun dir(ctx: Context): File = File(ctx.filesDir, "capture_inbox").apply { mkdirs() }

    fun add(ctx: Context, source: String, text: String, sender: String?, pkg: String?, platformId: String?): String? {
        if (text.isBlank()) return null
        val d = dir(ctx)
        if ((d.list()?.size ?: 0) >= MAX_EVENTS) return null
        val id = UUID.randomUUID().toString()
        val o = JSONObject()
            .put("id", id)
            .put("source", source)
            .put("text", text.take(MAX_TEXT))
            .put("receivedAt", Instant.now().toString())
            .put("platformId", platformId ?: id)
        if (!sender.isNullOrBlank()) o.put("sender", sender.take(64))
        if (!pkg.isNullOrBlank()) o.put("package", pkg)
        val tmp = File(d, "$id.tmp")
        tmp.writeText(o.toString())
        tmp.renameTo(File(d, "$id.json"))
        listener?.invoke()
        return id
    }

    fun pending(ctx: Context): List<Map<String, Any?>> =
        (dir(ctx).listFiles { f -> f.name.endsWith(".json") } ?: emptyArray())
            .sortedBy { it.lastModified() }
            .mapNotNull { f ->
                try {
                    val o = JSONObject(f.readText())
                    o.keys().asSequence().associateWith { k -> o.get(k).let { if (it == JSONObject.NULL) null else it } }
                } catch (e: Exception) {
                    f.delete(); null
                }
            }

    fun remove(ctx: Context, ids: List<String>) {
        val d = dir(ctx)
        ids.filter { it.isNotBlank() && !it.contains('/') }.forEach { File(d, "$it.json").delete() }
    }
}
