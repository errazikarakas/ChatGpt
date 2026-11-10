package com.carriez.flutter_hbb

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.ApplicationInfo
import android.app.Activity
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Uses Android's own package identity in addition to the signed feed digest. */
class BakimUpdateValidationException(val reason: String) : Exception(reason)
object BakimUpdater {
    const val PUBLISHER = "8965892c1419f7bcdead4dc152c8b2916d43e3a8e71521cd7e0ac4d6333e7341"
    const val PACKAGE = "tr.bakim.yardim"
    const val CHANNEL = "bakim.tr/yardim-updater"
    private var updaterChannel: MethodChannel? = null
    /** Called only from the worker; a missing/busy Dart session fails closed. */
    fun canInstallWhenIdle(activity: Activity): Boolean {
        val done = CountDownLatch(1)
        var allowed = false
        activity.runOnUiThread {
            val channel = updaterChannel
            if (channel == null) { done.countDown() }
            else channel.invokeMethod("canInstallNow", null, object : MethodChannel.Result {
                override fun success(result: Any?) { allowed = result == true; done.countDown() }
                override fun error(code: String, message: String?, details: Any?) { done.countDown() }
                override fun notImplemented() { done.countDown() }
            })
        }
        return done.await(5, TimeUnit.SECONDS) && allowed
    }
    fun preferences(context: Context) = context.getSharedPreferences("bakim-yardim-updater", Context.MODE_PRIVATE)
    fun directory(context: Context) = File(context.cacheDir, "bakim-updates").apply { mkdirs() }
    fun trace(context: Context, stage: String, error: Exception? = null) {
        if ((context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) == 0) return
        val code = if (error is BakimUpdateValidationException) error.reason else error?.javaClass?.simpleName
        val prefs = preferences(context)
        val history = (prefs.getString("updateTrace", "") ?: "").takeLast(2000)
        val edit = prefs.edit().putString("lastUpdateStage", stage).putString("updateTrace", "$history,$stage")
        if (code != null) edit.putString("lastUpdateError", code)
        edit.apply()
        Log.i("BakimUpdater", "stage=$stage" + if (code == null) "" else " error=$code")
    }
    private fun verified(ok: Boolean, code: String) { if (!ok) throw BakimUpdateValidationException(code) }
    @Suppress("DEPRECATION")
    fun version(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    fun flags(): Int = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    fun certificate(info: PackageInfo): String {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        require(signatures != null && signatures.size == 1) { "Unexpected APK signer count" }
        return MessageDigest.getInstance("SHA-256").digest(signatures[0].toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    @Suppress("DEPRECATION")
    fun installed(context: Context): PackageInfo = context.packageManager.getPackageInfo(context.packageName, flags())
    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val buffer = ByteArray(65536); while (true) { val read = input.read(buffer); if (read < 0) break; digest.update(buffer, 0, read) } }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    @Suppress("DEPRECATION")
    fun validate(context: Context, fileName: String, expectedVersion: Long, digest: String, size: Long): File {
        verified(context.packageName == PACKAGE && expectedVersion in 1..2147483647L, "invalid_update_identity")
        verified(fileName == "bakim-$expectedVersion.apk" && Regex("^[0-9a-f]{64}$").matches(digest), "invalid_update_metadata")
        val file = File(directory(context), fileName)
        verified(file.canonicalFile.parentFile == directory(context).canonicalFile && file.isFile, "private_apk_missing")
        verified(file.length() == size && size in 1024..167772160L, "apk_size_mismatch")
        verified(sha256(file) == digest, "apk_sha256_mismatch")
        val current = installed(context)
        verified(certificate(current) == PUBLISHER && expectedVersion > version(current), "installed_publisher_or_version_mismatch")
        val update = context.packageManager.getPackageArchiveInfo(file.absolutePath, flags()) ?: throw BakimUpdateValidationException("apk_parse_failed")
        verified(update.packageName == PACKAGE, "apk_package_mismatch")
        verified(version(update) == expectedVersion, "apk_version_mismatch")
        verified(certificate(update) == PUBLISHER, "apk_publisher_mismatch")
        if (Build.VERSION.SDK_INT >= 24) verified(update.applicationInfo!!.minSdkVersion <= Build.VERSION.SDK_INT, "apk_sdk_unsupported")
        return file
    }
    fun register(activity: MainActivity, engine: FlutterEngine) {
        BakimUpdateReceiver.dismissNotification(activity)
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        updaterChannel = channel
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> {
                        val info = installed(activity)
                        result.success(mapOf("packageName" to activity.packageName, "versionCode" to version(info),
                            "versionName" to info.versionName, "sdkInt" to Build.VERSION.SDK_INT,
                            "certificateSha256" to certificate(info), "cacheDirectory" to directory(activity).absolutePath,
                            "deferUpdatesUntil" to preferences(activity).getLong("deferUntil", 0)))
                    }
                    "install" -> {
                        trace(activity, "native_install_requested")
                        val fileName = call.argument<String>("fileName") ?: error("Missing APK")
                        val version = (call.argument<Number>("versionCode") ?: error("Missing version")).toLong()
                        val hash = call.argument<String>("sha256") ?: error("Missing checksum")
                        val size = (call.argument<Number>("size") ?: error("Missing size")).toLong()
                        require(call.argument<String>("certificateSha256") == PUBLISHER)
                        require(fileName == "bakim-$version.apk" && Regex("^[0-9a-f]{64}$").matches(hash))
                        activity.startActivity(Intent(activity, BakimUpdateActivity::class.java)
                            .putExtra("fileName", fileName).putExtra("version", version).putExtra("digest", hash).putExtra("size", size))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) { trace(activity, "native_channel_failed", error); result.error("update_unavailable", "Güncelleme daha sonra yeniden denenecek.", null) }
        }
    }
}
