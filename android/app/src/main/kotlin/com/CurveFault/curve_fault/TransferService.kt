package com.CurveFault.curve_fault

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Keeps the Dart isolate alive while a peer transfer runs in the background.
 *
 * The actual WebRTC work stays in Flutter; this service only raises the
 * process priority and shows the required foreground notification.
 */
class TransferService : Service() {
    companion object {
        private const val CHANNEL_ID = "curve_vault_transfer"
        private const val NOTIFICATION_ID = 4701
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("CurveVault transfer")
            .setContentText("Keep CurveVault open, or return to it, to finish the transfer.")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        startForeground(NOTIFICATION_ID, notification)
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
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
