package dk.langkilde.mindmill

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/** Keeps a voice conversation or a live meeting going with the screen off (foreground service, type microphone). */
class MicService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = application as MindmillApp
        when (intent?.action) {
            ACTION_END_VOICE -> app.voice.end()
            ACTION_STOP -> { stopSelf(); return START_NOT_STICKY }
        }
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Mindmill is listening"
        val notification = notification(this, text, showEnd = intent?.getBooleanExtra(EXTRA_VOICE, false) == true)
        val type = if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
        runCatching { ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type) }
            .onFailure { stopSelf() }
        return START_NOT_STICKY
    }

    companion object {
        private const val CHANNEL = "conversation"
        private const val NOTIFICATION_ID = 41
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_VOICE = "voice"
        private const val ACTION_END_VOICE = "dk.langkilde.mindmill.END_VOICE"
        private const val ACTION_STOP = "dk.langkilde.mindmill.STOP_MIC"

        /** Starts, updates or stops the service for what currently uses the microphone. */
        fun update(context: Context, voice: Boolean, meeting: Boolean) {
            if (!voice && !meeting) {
                context.stopService(Intent(context, MicService::class.java))
                return
            }
            val text = when {
                voice && meeting -> "Talking and recording a meeting"
                voice -> "In a voice conversation with your Mac"
                else -> "Recording a meeting"
            }
            val i = Intent(context, MicService::class.java).putExtra(EXTRA_TEXT, text).putExtra(EXTRA_VOICE, voice)
            runCatching { ContextCompat.startForegroundService(context, i) }
        }

        fun ensureChannel(context: Context) {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Conversations and meetings", NotificationManager.IMPORTANCE_LOW),
            )
        }

        private fun notification(context: Context, text: String, showEnd: Boolean): Notification {
            ensureChannel(context)
            val open = PendingIntent.getActivity(
                context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_mindmill)
                .setContentTitle("Mindmill")
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(open)
                .apply {
                    if (showEnd) {
                        val end = PendingIntent.getService(
                            context, 1, Intent(context, MicService::class.java).setAction(ACTION_END_VOICE),
                            PendingIntent.FLAG_IMMUTABLE,
                        )
                        addAction(0, "End conversation", end)
                    }
                }
                .build()
        }
    }
}
