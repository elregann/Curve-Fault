package com.CurveFault.curve_fault

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
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps the Dart isolate alive while a peer transfer runs in the background.
 *
 * The actual WebRTC work stays in Flutter; this service raises the process
 * priority, holds a partial wakelock so the CPU keeps servicing the data
 * channel, and shows the required foreground notification.
 */
class TransferService : Service() {
    companion object {
        private const val CHANNEL_ID = "curve_vault_transfer"
        private const val NOTIFICATION_ID = 4701
        private const val WAKE_LOCK_TAG = "CurveVault:Transfer"
        private const val WAKE_LOCK_TIMEOUT_MS = 6 * 60 * 60 * 1000L

        const val EXTRA_MODE = "mode"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"

        private const val DEFAULT_TITLE = "CurveVault transfer"
        private const val DEFAULT_TEXT =
            "Waiting for the other device. You can switch apps while this runs."

        private data class PendingUpdate(
            val mode: String?,
            val title: String?,
            val text: String?,
            val progress: Int,
        )

        @Volatile
        private var running = false

        /** True between a start request and the service reaching onStartCommand. */
        @Volatile
        private var starting = false

        private var pendingUpdate: PendingUpdate? = null
        private var startedAt = 0L

        /** Keeps updates that arrive while the service is still warming up. */
        fun markStarting() {
            starting = true
            pendingUpdate = null
        }

        /** Drops late updates so they cannot surface in a later session. */
        fun markStopping() {
            starting = false
            running = false
            pendingUpdate = null
        }

        /** Refreshes the notification, but never recreates a stopped one. */
        fun update(
            context: Context,
            mode: String?,
            title: String?,
            text: String?,
            progress: Int,
        ) {
            if (!running) {
                if (starting) {
                    pendingUpdate = PendingUpdate(mode, title, text, progress)
                }
                return
            }
            pendingUpdate = null
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, build(context, mode, title, text, progress))
        }

        private fun build(
            context: Context,
            mode: String?,
            title: String?,
            text: String?,
            progress: Int,
        ): Notification {
            val icon = if (mode == "transferring") {
                R.drawable.ic_stat_transfer_active
            } else {
                R.drawable.ic_stat_transfer_wait
            }
            val lockScreenVersion = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(icon)
                .setContentTitle("Secret file transfer")
                .setContentText("Tap to open CurveVault")
                .build()
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle(title ?: DEFAULT_TITLE)
                .setContentText(text ?: DEFAULT_TEXT)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text ?: DEFAULT_TEXT))
                .setSmallIcon(icon)
                .setOngoing(true)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(lockScreenVersion)
                .setWhen(if (startedAt > 0L) startedAt else System.currentTimeMillis())
            val openApp = contentIntent(context)
            if (openApp != null) builder.setContentIntent(openApp)
            when (mode) {
                "transferring" -> builder.setProgress(100, progress.coerceIn(0, 100), false)
                "connecting" -> builder.setProgress(0, 0, true)
            }
            return builder.build()
        }

        /** Opens the running app instead of starting a second copy of it. */
        private fun contentIntent(context: Context): PendingIntent? {
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: return null
            launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            return PendingIntent.getActivity(
                context,
                0,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
            .apply { setReferenceCounted(false) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (startedAt == 0L) startedAt = System.currentTimeMillis()
        val notification = build(
            this,
            intent?.getStringExtra(EXTRA_MODE),
            intent?.getStringExtra(EXTRA_TITLE),
            intent?.getStringExtra(EXTRA_TEXT),
            intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0,
        )

        val foregroundType =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, foregroundType)
        running = true
        starting = false
        val pending = pendingUpdate
        if (pending != null) {
            pendingUpdate = null
            update(this, pending.mode, pending.title, pending.text, pending.progress)
        }

        val lock = wakeLock
        if (lock != null && !lock.isHeld) {
            lock.acquire(WAKE_LOCK_TIMEOUT_MS)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        markStopping()
        val lock = wakeLock
        if (lock != null && lock.isHeld) {
            lock.release()
        }
        wakeLock = null
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                CHANNEL_ID,
                "File transfers",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while a secret file transfer is running"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }
}
