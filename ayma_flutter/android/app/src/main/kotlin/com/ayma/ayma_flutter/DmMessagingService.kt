package com.ayma.ayma_flutter

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.Typeface
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService
import java.net.HttpURLConnection
import java.net.URL

/**
 * Renders incoming DM pushes as a WhatsApp / iMessage style conversation
 * notification: the sender's round profile picture, their name as the title,
 * the message as the body, and one notification per conversation that stacks
 * new messages ([NotificationCompat.MessagingStyle]).
 *
 * The backend sends DMs as data-only FCM messages (`type = dm`), so this runs
 * whether the app is foreground, background or killed. Every other push is
 * passed straight to the firebase_messaging plugin's service, unchanged.
 *
 * While the app is in the foreground nothing is posted (the in-app thread /
 * inbox already shows the message) — the same as a notification-payload push
 * has always behaved.
 */
class DmMessagingService : FlutterFirebaseMessagingService() {

    companion object {
        private const val TAG = "DmMessagingService"
        const val CHANNEL_ID = "ayma_dm_messages"
        // Not "deep_link": FCM copies its data keys into the launch intent of a
        // system-tray push, which would double-route through firebase_messaging.
        const val EXTRA_DEEP_LINK = "ayma_dm_deep_link"
        private const val AVATAR_PX = 192
        private const val NETWORK_TIMEOUT_MS = 4000
        private const val MAX_AVATAR_BYTES = 2 * 1024 * 1024
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        if (data["type"] != "dm") {
            super.onMessageReceived(message)
            return
        }
        if (MainActivity.isResumed) return
        try {
            showDm(data)
        } catch (e: Exception) {
            Log.w(TAG, "DM notification failed", e)
        }
    }

    private fun showDm(data: Map<String, String>) {
        val threadId = data["thread_id"].orEmpty()
        val deepLink = data["deep_link"].orEmpty()
        if (threadId.isEmpty()) return
        val senderName = data["sender_name"].orEmpty().ifBlank { "New message" }
        val text = data["body"].orEmpty()
        val sentAt = data["sent_at_ms"]?.toLongOrNull() ?: System.currentTimeMillis()

        val nm = NotificationManagerCompat.from(this)
        ensureChannel()

        // The avatar download is the only slow step; a failure just means
        // initials instead of a photo — never a dropped notification.
        val avatar = circleCrop(downloadAvatar(data["sender_photo_url"].orEmpty()))
            ?: initialsAvatar(senderName)

        val sender = Person.Builder()
            .setName(senderName)
            .setKey(data["sender_uid"].orEmpty().ifBlank { threadId })
            .setIcon(IconCompat.createWithBitmap(avatar))
            .build()

        val notificationId = threadId.hashCode()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val existing = manager.activeNotifications
            .firstOrNull { it.id == notificationId }?.notification
        val style = existing?.let {
            NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(it)
        } ?: NotificationCompat.MessagingStyle(
            Person.Builder().setName("Me").build()
        )
        style.addMessage(NotificationCompat.MessagingStyle.Message(text, sentAt, sender))

        val tap = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_DEEP_LINK, deepLink)
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            notificationId,
            tap,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(ContextCompat.getColor(this, R.color.ayma_accent))
            .setLargeIcon(avatar)
            .setContentTitle(senderName)
            .setContentText(text)
            .setStyle(style)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setWhen(sentAt)
            .setShowWhen(true)
            .setOnlyAlertOnce(false)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()

        try {
            nm.notify(notificationId, notification)
        } catch (e: SecurityException) {
            Log.w(TAG, "POST_NOTIFICATIONS not granted", e)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Messages", NotificationManager.IMPORTANCE_HIGH)
        )
    }

    private fun downloadAvatar(url: String): Bitmap? {
        if (!url.startsWith("https://")) return null
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = NETWORK_TIMEOUT_MS
                readTimeout = NETWORK_TIMEOUT_MS
            }
            if (conn.responseCode != HttpURLConnection.HTTP_OK) return null
            if (conn.contentLength > MAX_AVATAR_BYTES) return null
            val bytes = conn.inputStream.use { it.readBytes() }
            if (bytes.size > MAX_AVATAR_BYTES) return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= AVATAR_PX &&
                bounds.outHeight / (sample * 2) >= AVATAR_PX
            ) sample *= 2
            BitmapFactory.decodeByteArray(
                bytes, 0, bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sample }
            )
        } catch (e: Exception) {
            Log.w(TAG, "avatar download failed", e)
            null
        } finally {
            conn?.disconnect()
        }
    }

    /** Center-crops [src] to a square and masks it to a circle. */
    private fun circleCrop(src: Bitmap?): Bitmap? {
        if (src == null) return null
        val side = minOf(src.width, src.height)
        val out = Bitmap.createBitmap(AVATAR_PX, AVATAR_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        canvas.drawCircle(AVATAR_PX / 2f, AVATAR_PX / 2f, AVATAR_PX / 2f, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        val from = Rect((src.width - side) / 2, (src.height - side) / 2,
            (src.width + side) / 2, (src.height + side) / 2)
        canvas.drawBitmap(src, from, Rect(0, 0, AVATAR_PX, AVATAR_PX), paint)
        return out
    }

    /** Accent-colored circle with the sender's initial — the no-photo fallback. */
    private fun initialsAvatar(name: String): Bitmap {
        val out = Bitmap.createBitmap(AVATAR_PX, AVATAR_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.color = ContextCompat.getColor(this, R.color.ayma_accent)
        canvas.drawCircle(AVATAR_PX / 2f, AVATAR_PX / 2f, AVATAR_PX / 2f, paint)
        paint.color = 0xFFFFFFFF.toInt()
        paint.textSize = AVATAR_PX * 0.5f
        paint.textAlign = Paint.Align.CENTER
        paint.typeface = Typeface.DEFAULT_BOLD
        val initial = name.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"
        val y = AVATAR_PX / 2f - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText(initial, AVATAR_PX / 2f, y, paint)
        return out
    }
}
