package kw.fils.fils

import android.app.Notification
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.security.MessageDigest

/**
 * Captures notifications ONLY from bank/wallet apps the user explicitly selected.
 * Everything else returns immediately: it is never read, logged or stored.
 * Messaging apps (SMS inbox notifications) are rejected even if selected, so
 * notification access is never used as a workaround for SMS permission policy.
 */
class FilsNotificationListener : NotificationListenerService() {

    companion object {
        const val PREFS = "fils_capture"
        const val KEY_PACKAGES = "monitored_packages"
        const val KEY_LAST_EVENT = "last_event_at"
        const val KEY_CONNECTED = "listener_connected"
        private val BLOCKED_PACKAGES = setOf(
            "com.google.android.apps.messaging",
            "com.samsung.android.messaging",
            "com.android.mms",
            "com.android.messaging",
            "com.whatsapp",
            "org.telegram.messenger",
        )

        fun monitored(ctx: Context): Set<String> =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getStringSet(KEY_PACKAGES, emptySet())!!
                .filterNot { BLOCKED_PACKAGES.contains(it) }.toSet()

        fun isBlocked(pkg: String) = BLOCKED_PACKAGES.contains(pkg)
    }

    private val recent = LinkedHashMap<String, Long>()

    override fun onListenerConnected() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(KEY_CONNECTED, true).apply()
    }

    override fun onListenerDisconnected() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(KEY_CONNECTED, false).apply()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val pkg = sbn.packageName ?: return
        if (!monitored(this).contains(pkg)) return // filter BEFORE reading any content
        val n = sbn.notification ?: return
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = n.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        val big = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
        val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.joinToString("\n")
        val body = listOfNotNull(big ?: text, lines).joinToString("\n").trim()
        if (body.isEmpty()) return // redacted ("Contents hidden") or empty

        // Updated notifications re-post the same content: dedupe by key + content hash.
        val hash = sha256("$pkg|$body")
        val now = System.currentTimeMillis()
        synchronized(recent) {
            val prev = recent[hash]
            if (prev != null && now - prev < 10 * 60_000) return
            recent[hash] = now
            if (recent.size > 200) recent.remove(recent.keys.first())
        }
        val platformId = "${sbn.key}|$hash"
        CaptureInbox.add(this, "notification", if (title != null) "$title\n$body" else body, title, pkg, platformId)
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putLong(KEY_LAST_EVENT, now).apply()
        // Process now if the UI isn't running (headless engine); otherwise the UI drains.
        HeadlessCaptureRunner.request(this)
    }

    private fun sha256(s: String): String =
        MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }.take(32)
}
