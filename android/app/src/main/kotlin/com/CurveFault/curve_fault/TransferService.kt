package com.CurveFault.curve_fault

import android.app.NotificationChannel
import android.app.NotificationManager
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
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("CurveVault transfer")
            .setContentText("A secret file transfer is active. You can switch apps.")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        val foregroundType =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, foregroundType)

        val lock = wakeLock
        if (lock != null && !lock.isHeld) {
            lock.acquire(WAKE_LOCK_TIMEOUT_MS)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
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
