package com.bgallagher.rackoon.terminal

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import com.bgallagher.rackoon.MainActivity
import com.bgallagher.rackoon.RackoonApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Keeps the process (and so the open SSH sessions) alive while terminals are open, with the notification Android requires.
 * It holds no logic: it shows the session count and stops itself when the last tab closes.
 */
class SessionService : Service() {
    private val scope = CoroutineScope(Dispatchers.Main.immediate)
    private var watcher: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Open terminal sessions", NotificationManager.IMPORTANCE_LOW))
        val manager = (application as RackoonApp).container.terminals
        startForeground(NOTIFICATION_ID, notification(manager.openCount.value.coerceAtLeast(1)), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        watcher?.cancel()
        watcher = scope.launch {
            manager.openCount.collect { n ->
                if (n == 0) stopSelf() else nm.notify(NOTIFICATION_ID, notification(n))
            }
        }
        return START_NOT_STICKY
    }

    private fun notification(count: Int): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_info_details)
            .setContentTitle("Rackoon")
            .setContentText(if (count == 1) "1 SSH session open" else "$count SSH sessions open")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        scope.cancel()
    }

    private companion object {
        const val CHANNEL = "sessions"
        const val NOTIFICATION_ID = 1
    }
}
