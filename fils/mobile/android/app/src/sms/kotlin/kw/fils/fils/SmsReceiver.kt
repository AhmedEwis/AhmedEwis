package kw.fils.fils

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

/**
 * SMS capture: ONLY compiled into the `sms` flavor, which may be distributed only after
 * Google Play approves the SMS permission declaration (or outside Play). Messages from
 * senders the user did not select are dropped without being stored.
 */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val allowed = ctx.getSharedPreferences(FilsNotificationListener.PREFS, Context.MODE_PRIVATE)
            .getStringSet("sms_senders", emptySet())!!
        val msgs = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        val bySender = msgs.groupBy { it.originatingAddress ?: "" }
        for ((sender, parts) in bySender) {
            if (!allowed.contains(sender.lowercase())) continue
            val body = parts.joinToString("") { it.messageBody ?: "" }
            val ts = parts.firstOrNull()?.timestampMillis ?: 0L
            CaptureInbox.add(ctx, "sms", body, sender, null, "sms|$sender|$ts|${body.hashCode()}")
            HeadlessCaptureRunner.request(ctx)
        }
    }
}
