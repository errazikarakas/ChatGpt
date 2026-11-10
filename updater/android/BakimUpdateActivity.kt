package com.carriez.flutter_hbb

import android.app.Activity
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import kotlin.concurrent.thread

/** Same-publisher self-update via public Android APIs; normal confirmation remains the fallback. */
class BakimUpdateActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var sessionId = -1
    @Volatile private var finishing = false
    @Volatile private var updateVisible = false
    private val timeout = Runnable { continueCurrent(defer = true) }
    private val expectedVersion: Long get() = intent.getLongExtra("version", 0)

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val box = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; setPadding(32, 32, 32, 32) }
        box.addView(TextView(this).apply { text = "Bakım.TR Yardım"; textSize = 23f; gravity = Gravity.CENTER })
        box.addView(TextView(this).apply { text = "Güvenli güncelleme hazırlanıyor…"; textSize = 16f; gravity = Gravity.CENTER; setPadding(0, 24, 0, 0) })
        setContentView(box)
        BakimUpdater.trace(this, "update_activity_created")
        sessionId = state?.getInt("sessionId", -1) ?: -1
        handler.postDelayed(timeout, 5 * 60 * 1000L)
        if (intent.hasExtra(PackageInstaller.EXTRA_STATUS)) handleStatus()
        else if (sessionId < 0) prepare()
    }
    override fun onNewIntent(newIntent: Intent) { super.onNewIntent(newIntent); intent = newIntent; if (intent.hasExtra(PackageInstaller.EXTRA_STATUS)) handleStatus() }
    override fun onSaveInstanceState(out: Bundle) { out.putInt("sessionId", sessionId); super.onSaveInstanceState(out) }
    override fun onResume() { super.onResume(); updateVisible = true }
    override fun onPause() { updateVisible = false; super.onPause() }
    override fun onDestroy() { handler.removeCallbacks(timeout); super.onDestroy() }

    private fun prepare() {
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            BakimUpdater.trace(this, "source_permission_required")
            Toast.makeText(this, "Güncelleme için Android'de bu kaynağa izin verin.", Toast.LENGTH_LONG).show()
            try { startActivityForResult(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")), 901) }
            catch (_: Exception) { continueCurrent(defer = true) }
            return
        }
        thread(name = "bakim-apk-verifier") {
            try {
                BakimUpdater.trace(this, "native_apk_validation_started")
                val file = BakimUpdater.validate(this, intent.getStringExtra("fileName") ?: "", expectedVersion,
                    intent.getStringExtra("digest") ?: "", intent.getLongExtra("size", 0))
                if (finishing || isDestroyed) return@thread
                BakimUpdater.trace(this, "native_apk_validation_passed")
                if (!BakimUpdater.canInstallWhenIdle(this)) {
                    BakimUpdater.trace(this, "live_session_kept_current_app")
                    runOnUiThread { continueCurrent(defer = false) }; return@thread
                }
                val installer = packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                    setAppPackageName(packageName); setSize(file.length())
                    // Public API supports a trusted app updating ITSELF without
                    // repeat confirmation. No installer identity or admin privilege
                    // is substituted. OEM/policy/older-device confirmation remains.
                    if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                    if (Build.VERSION.SDK_INT >= 33) setPackageSource(PackageInstaller.PACKAGE_SOURCE_DOWNLOADED_FILE)
                }
                sessionId = installer.createSession(params)
                BakimUpdater.trace(this, "native_session_created")
                if (finishing) { installer.abandonSession(sessionId); return@thread }
                // A status Activity is not reliable: Android intentionally sends
                // install results without background-activity launch privileges.
                // An explicit private receiver survives the package replacement
                // and can persist the real result before trying normal UI resume.
                val callback = Intent(this, BakimUpdateReceiver::class.java).apply {
                    action = "tr.bakim.yardim.UPDATE_RESULT"
                    putExtra("version", expectedVersion); putExtra("sessionId", sessionId)
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                val pending = PendingIntent.getBroadcast(this, sessionId, callback, flags)
                installer.openSession(sessionId).use { session ->
                    session.openWrite("base.apk", 0, file.length()).use { output -> file.inputStream().use { it.copyTo(output) }; session.fsync(output) }
                    if (finishing) { session.abandon(); return@thread }
                    if (!BakimUpdater.canInstallWhenIdle(this)) {
                        session.abandon(); BakimUpdater.trace(this, "live_session_kept_current_app")
                        runOnUiThread { continueCurrent(defer = false) }; return@thread
                    }
                    require(BakimUpdater.preferences(this).edit()
                        .putInt("pendingSessionId", sessionId).putLong("pendingVersion", expectedVersion)
                        .putLong("pendingCommitAt", System.currentTimeMillis())
                        .putBoolean("pendingForeground", updateVisible).commit())
                    BakimUpdater.trace(this, "native_session_committing")
                    session.commit(pending.intentSender)
                }
            } catch (error: Exception) { BakimUpdater.trace(this, "native_validation_or_session_failed", error); runOnUiThread { continueCurrent(defer = true) } }
        }
    }
    @Suppress("DEPRECATION")
    private fun handleStatus() {
        sessionId = intent.getIntExtra("sessionId", sessionId)
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                BakimUpdater.trace(this, "system_confirmation_required")
                val confirmation = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java) else intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirmation == null) { continueCurrent(defer = true); return }
                try { startActivityForResult(confirmation, 902) } catch (_: Exception) { continueCurrent(defer = true) }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                BakimUpdater.trace(this, "native_install_success")
                try {
                    val current = BakimUpdater.installed(this)
                    require(BakimUpdater.version(current) >= expectedVersion && BakimUpdater.certificate(current) == BakimUpdater.PUBLISHER)
                    BakimUpdater.preferences(this).edit().putLong("deferUntil", 0).putLong("lastInstalledVersion", BakimUpdater.version(current)).apply()
                    Toast.makeText(this, "Bakım.TR Yardım güncellendi.", Toast.LENGTH_SHORT).show()
                    continueCurrent(defer = false)
                } catch (_: Exception) { continueCurrent(defer = true) }
            }
            else -> { BakimUpdater.trace(this, "native_install_declined_or_failed"); continueCurrent(defer = true) }
        }
    }
    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 901) {
            if (Build.VERSION.SDK_INT >= 26 && packageManager.canRequestPackageInstalls()) { BakimUpdater.trace(this, "source_permission_granted"); prepare() } else { BakimUpdater.trace(this, "source_permission_declined"); continueCurrent(defer = true) }
        } else if (requestCode == 902 && resultCode == RESULT_CANCELED) continueCurrent(defer = true)
    }
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() { continueCurrent(defer = true) }
    private fun continueCurrent(defer: Boolean) {
        if (finishing) return
        finishing = true; handler.removeCallbacks(timeout)
        if (defer) {
            BakimUpdater.preferences(this).edit().putLong("deferUntil", System.currentTimeMillis() + 60 * 60 * 1000L).apply()
            if (sessionId >= 0) try { packageManager.packageInstaller.abandonSession(sessionId) } catch (_: Exception) {}
        }
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }
}
