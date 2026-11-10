package com.carriez.flutter_hbb

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/** Uses Android's own package identity in addition to the signed feed digest. */
object BakimUpdater {
    const val PUBLISHER = "8965892c1419f7bcdead4dc152c8b2916d43e3a8e71521cd7e0ac4d6333e7341"
    const val PACKAGE = "tr.bakim.yardim"
    const val CHANNEL = "bakim.tr/yardim-updater"
    fun preferences(context: Context) = context.getSharedPreferences("bakim-yardim-updater", Context.MODE_PRIVATE)
    fun directory(context: Context) = File(context.cacheDir, "bakim-updates").apply { mkdirs() }
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
        require(context.packageName == PACKAGE && expectedVersion in 1..2147483647L)
        require(fileName == "bakim-$expectedVersion.apk" && Regex("^[0-9a-f]{64}$").matches(digest))
        val file = File(directory(context), fileName)
        require(file.canonicalFile.parentFile == directory(context).canonicalFile && file.isFile)
        require(file.length() == size && size in 1024..167772160L && sha256(file) == digest)
        val current = installed(context)
        require(certificate(current) == PUBLISHER && expectedVersion > version(current))
        val update = context.packageManager.getPackageArchiveInfo(file.absolutePath, flags()) ?: error("APK cannot be parsed")
        require(update.packageName == PACKAGE && version(update) == expectedVersion && certificate(update) == PUBLISHER)
        if (Build.VERSION.SDK_INT >= 24) require(update.applicationInfo!!.minSdkVersion <= Build.VERSION.SDK_INT)
        return file
    }
    fun register(activity: MainActivity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
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
            } catch (_: Exception) { result.error("update_unavailable", "Güncelleme daha sonra yeniden denenecek.", null) }
        }
    }
}
