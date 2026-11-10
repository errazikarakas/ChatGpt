package com.carriez.flutter_hbb

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

/** Explicit, non-exported install-result receiver. No special launch privilege. */
class BakimUpdateReceiver : BroadcastReceiver() {
    companion object {
        const val NOTIFICATION_ID = 48218
        private const val NOTIFICATION_CHANNEL = "bakim-update-complete"
        fun dismissNotification(context: Context) {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIFICATION_ID)
        }
    }

    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "tr.bakim.yardim.UPDATE_RESULT") return
        val prefs = BakimUpdater.preferences(context)
        val sessionId = prefs.getInt("pendingSessionId", -1)
        val expectedVersion = prefs.getLong("pendingVersion", 0)
        // Android fills in EXTRA_SESSION_ID; also bind it to our private state.
        if (sessionId < 0 || expectedVersion <= 0 ||
            intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -2) != sessionId ||
            intent.getIntExtra("sessionId", -3) != sessionId ||
            intent.getLongExtra("version", 0) != expectedVersion) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            BakimUpdater.trace(context, "system_confirmation_required")
            val confirmation = if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            else intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            if (confirmation != null) try {
                context.startActivity(Intent(context, BakimUpdateActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra("version", expectedVersion).putExtra("sessionId", sessionId)
                    .putExtra(PackageInstaller.EXTRA_STATUS, status).putExtra(Intent.EXTRA_INTENT, confirmation))
            } catch (error: Exception) { BakimUpdater.trace(context, "system_confirmation_launch_failed", error) }
            return
        }
        if (status != PackageInstaller.STATUS_SUCCESS) {
            BakimUpdater.trace(context, "native_install_declined_or_failed")
            val wasForeground = prefs.getBoolean("pendingForeground", false)
            prefs.edit().remove("pendingSessionId").remove("pendingVersion")
                .putLong("deferUntil", System.currentTimeMillis() + 60 * 60 * 1000L).apply()
            // A terminal failure must release the still-visible preparation
            // page immediately; do not leave it waiting for the timeout.
            if (wasForeground) try {
                context.startActivity(Intent(context, BakimUpdateActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    .putExtra("version", expectedVersion).putExtra("sessionId", sessionId)
                    .putExtra(PackageInstaller.EXTRA_STATUS, status))
            } catch (error: Exception) { BakimUpdater.trace(context, "failed_update_ui_resume_unavailable", error) }
            return
        }
        try {
            val current = BakimUpdater.installed(context)
            require(current.packageName == BakimUpdater.PACKAGE &&
                BakimUpdater.version(current) >= expectedVersion &&
                BakimUpdater.certificate(current) == BakimUpdater.PUBLISHER)
            val committedAt = prefs.getLong("pendingCommitAt", 0)
            val continueForeground = prefs.getBoolean("pendingForeground", false) &&
                System.currentTimeMillis() - committedAt in 0..600000L
            require(prefs.edit().putLong("lastInstalledVersion", BakimUpdater.version(current))
                .putLong("deferUntil", 0).remove("pendingSessionId").remove("pendingVersion").commit())
            BakimUpdater.trace(context, "native_install_success_receiver")

            // Resume only the update the user just had in front of them. This is
            // an ordinary startActivity call; Android's task/BAL rules still
            // decide whether it may appear. No overlay, service, task-reordering
            // permission, alarm, device admin or identity substitution is used.
            if (continueForeground) try {
                BakimUpdater.trace(context, "normal_foreground_update_resume_requested")
                context.startActivity(mainIntent(context))
            } catch (error: Exception) { BakimUpdater.trace(context, "normal_update_resume_unavailable", error) }
            offerNotificationIfAlreadyAllowed(context)
        } catch (error: Exception) { BakimUpdater.trace(context, "installed_result_validation_failed", error) }
    }

    private fun mainIntent(context: Context) = Intent(context, MainActivity::class.java)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    private fun offerNotificationIfAlreadyAllowed(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // Never ask for a new permission merely to reopen an already updated app.
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            BakimUpdater.trace(context, "completion_notification_permission_not_granted"); return
        }
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) {
            BakimUpdater.trace(context, "completion_notifications_disabled"); return
        }
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(
            NOTIFICATION_CHANNEL, "Uygulama güncellemeleri", NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, NOTIFICATION_ID, mainIntent(context),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, NOTIFICATION_CHANNEL) else Notification.Builder(context)
        manager.notify(NOTIFICATION_ID, builder.setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Bakım.TR Yardım güncellendi")
            .setContentText("Yardıma devam etmek için dokunun.")
            .setContentIntent(open).setAutoCancel(true).build())
        BakimUpdater.trace(context, "completion_notification_posted")
    }
}
