package com.machinee.audioshare

import android.content.Intent
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONArray
import android.os.Build
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var testTone: ToneGenerator? = null
    private var releaseToneRunnable: Runnable? = null
    private lateinit var companionController: CompanionController
    private val downloading = AtomicBoolean(false)
    @Volatile private var destroyed = false
    @Volatile private var updateConnection: HttpURLConnection? = null
    private var progressSink: EventChannel.EventSink? = null
    private var lastProgress: Map<String, Any>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        companionController = CompanionController(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.machinee.audioshare/preferences")
            .setMethodCallHandler { call, result ->
                val preferences = getSharedPreferences("appearance", MODE_PRIVATE)
                when (call.method) {
                    "readThemeMode" -> result.success(preferences.getString("themeMode", "system"))
                    "writeThemeMode" -> {
                        val mode = call.argument<String>("mode")
                        if (mode !in listOf("light", "dark", "system")) {
                            result.error("invalid_theme", "Unknown appearance", null)
                        } else {
                            preferences.edit().putString("themeMode", mode).apply()
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "openBluetoothSettings" -> {
                            startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                            result.success(null)
                        }
                        // Compatibility channel names; never proxy application
                        // gain requests to Android's global STREAM_MUSIC volume.
                        "getMediaVolume" -> result.success(mapOf(
                            "available" to false,
                            "current" to 0,
                            "max" to 0,
                            "fixed" to true,
                            "message" to "当前蓝牙模式暂不支持独立音量与增益。",
                        ))
                        "setMediaVolume" -> result.error(
                            "independent_volume_unavailable",
                            "当前蓝牙模式暂不支持独立音量与增益。",
                            null,
                        )
                        "playTestTone" -> {
                            playMediaTestTone()
                            result.success(null)
                        }
                        "stopTestTone" -> {
                            stopMediaTestTone()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (exception: Exception) {
                    result.error(
                        "android_error",
                        exception.message ?: "Android operation failed",
                        exception.javaClass.simpleName,
                    )
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "${UPDATE_CHANNEL}_progress")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    progressSink = events
                    lastProgress?.let(events::success)
                }
                override fun onCancel(arguments: Any?) { progressSink = null }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkForUpdate" -> checkForUpdate(result)
                    "downloadAndInstall" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("invalid_argument", "update URL is required", null)
                        } else {
                            downloadAndInstall(url, call.argument<String>("requestId") ?: "", result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onStop() {
        stopMediaTestTone()
        if (::companionController.isInitialized) companionController.onStop()
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        if (::companionController.isInitialized) companionController.onResume()
    }

    override fun onDestroy() {
        destroyed = true
        updateConnection?.disconnect()
        progressSink = null
        if (::companionController.isInitialized) companionController.destroy()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (::companionController.isInitialized) companionController.handleIntent(intent)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (::companionController.isInitialized) companionController.onRequestPermissionsResult(requestCode)
    }

    private fun playMediaTestTone() {
        stopMediaTestTone()

        // ToneGenerator is used only as a short test signal routed on the media stream;
        // this is not a voice-call tone and does not use the call audio stream.
        val tone = ToneGenerator(AudioManager.STREAM_MUSIC, TEST_TONE_VOLUME_PERCENT)
        if (!tone.startTone(ToneGenerator.TONE_DTMF_0, TEST_TONE_DURATION_MS)) {
            tone.release()
            throw IllegalStateException("Unable to start media test tone")
        }
        testTone = tone
        releaseToneRunnable = Runnable { stopMediaTestTone() }.also {
            mainHandler.postDelayed(it, TEST_TONE_DURATION_MS.toLong())
        }
    }

    private fun stopMediaTestTone() {
        releaseToneRunnable?.let(mainHandler::removeCallbacks)
        releaseToneRunnable = null
        testTone?.run {
            stopTone()
            release()
        }
        testTone = null
    }

    private fun checkForUpdate(result: MethodChannel.Result) {
        Thread {
            try {
                val connection = URL(LATEST_RELEASE_URL).openConnection() as HttpURLConnection
                connection.connectTimeout = NETWORK_TIMEOUT_MS
                connection.readTimeout = NETWORK_TIMEOUT_MS
                connection.requestMethod = "GET"
                connection.setRequestProperty("Accept", "application/vnd.github+json")
                connection.setRequestProperty("User-Agent", "AudioShare/${currentVersionName()}")
                try {
                    val code = connection.responseCode
                    if (code !in 200..299) {
                        val message = when (code) {
                            403, 429 -> "更新服务暂时限制了请求，请稍后重试"
                            404 -> "更新发布地址暂不可用，请稍后重试"
                            else -> "更新服务器暂不可用（HTTP $code）"
                        }
                        throw IllegalStateException(message)
                    }
                    val payload = JSONArray(connection.inputStream.bufferedReader().use { it.readText() })
                    val releases = (0 until payload.length()).map { index ->
                        val release = payload.getJSONObject(index)
                        val assets = release.optJSONArray("assets") ?: JSONArray()
                        AppRelease(
                            release.optString("tag_name"),
                            (0 until assets.length()).map { assetIndex ->
                                val asset = assets.getJSONObject(assetIndex)
                                ReleaseAsset(asset.optString("name"), asset.optString("browser_download_url"))
                            },
                            release.optBoolean("draft"), release.optBoolean("prerelease"),
                        )
                    }
                    val update = AndroidReleaseSelector.select(releases, currentVersionName(), Build.SUPPORTED_ABIS.toList())
                    mainHandler.post { result.success(update) }
                } finally {
                    connection.disconnect()
                }
            } catch (exception: Exception) {
                mainHandler.post {
                    result.error(
                        "update_check_failed",
                        when (exception) {
                            is java.io.IOException -> "无法连接更新服务，请检查网络后重试"
                            is org.json.JSONException -> "更新服务返回了无法识别的数据，请稍后重试"
                            else -> exception.message ?: "检查更新失败，请稍后重试"
                        },
                        exception.javaClass.simpleName,
                    )
                }
            }
        }.start()
    }

    private fun reportDownload(requestId: String, received: Long, total: Long, stage: String) {
        mainHandler.post {
            if (!destroyed) {
                val event = mapOf("requestId" to requestId, "received" to received,
                    "total" to total, "stage" to stage)
                lastProgress = event
                progressSink?.success(event)
            }
        }
    }

    private fun downloadAndInstall(url: String, requestId: String, result: MethodChannel.Result) {
        if (!downloading.compareAndSet(false, true)) {
            result.error("update_busy", "正在下载更新，请稍候", null)
            return
        }
        reportDownload(requestId, 0, 0, "connecting")
        Thread {
            val updateDirectory = File(cacheDir, "updates")
            val partial = File(updateDirectory, "$APK_ASSET_NAME.${System.nanoTime()}.part")
            try {
                updateDirectory.mkdirs()
                val apk = File(updateDirectory, APK_ASSET_NAME)
                val connection = URL(url).openConnection() as HttpURLConnection
                updateConnection = connection
                connection.connectTimeout = NETWORK_TIMEOUT_MS
                connection.readTimeout = NETWORK_TIMEOUT_MS
                connection.requestMethod = "GET"
                connection.setRequestProperty("User-Agent", "AudioShare/${currentVersionName()}")
                connection.setRequestProperty("Accept-Encoding", "identity")
                try {
                    if (connection.responseCode !in 200..299) {
                        throw IllegalStateException("APK 下载失败：HTTP ${connection.responseCode}")
                    }
                    val total = connection.contentLengthLong.coerceAtLeast(0)
                    connection.inputStream.use { input ->
                        partial.outputStream().use { output ->
                            copyUpdate(input, output, total, cancelled = { destroyed }) { received, size ->
                                reportDownload(requestId, received, size, "downloading")
                            }
                        }
                    }
                } finally {
                    connection.disconnect()
                    updateConnection = null
                }
                if (destroyed) throw java.io.IOException("下载已取消")
                if (!partial.renameTo(apk)) throw java.io.IOException("无法保存安装包，请重试")
                reportDownload(requestId, apk.length(), apk.length(), "installing")
                val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                mainHandler.post {
                    downloading.set(false)
                    if (destroyed) return@post
                    try {
                        startActivity(intent)
                        result.success(null)
                    } catch (exception: Exception) {
                        result.error("update_install_failed", "无法打开安装器，请检查应用安装权限", null)
                    }
                }
            } catch (exception: Exception) {
                partial.delete()
                mainHandler.post {
                    downloading.set(false)
                    if (destroyed) return@post
                    result.error(
                        "update_install_failed",
                        exception.message ?: "下载或安装更新失败",
                        exception.javaClass.simpleName,
                    )
                }
            }
        }.start()
    }

    @Suppress("DEPRECATION")
    private fun currentVersionName(): String =
        packageManager.getPackageInfo(packageName, 0).versionName ?: "0.0.0"

    companion object {
        private const val CHANNEL = "com.machinee.audioshare/external_route"
        private const val UPDATE_CHANNEL = "com.machinee.audioshare/update"
        private const val LATEST_RELEASE_URL =
            "https://api.github.com/repos/Machine-e/audioshare/releases?per_page=100"
        private const val APK_ASSET_NAME = "AudioShare-Android.apk"
        private const val NETWORK_TIMEOUT_MS = 15_000
        private const val TEST_TONE_VOLUME_PERCENT = 20
        private const val TEST_TONE_DURATION_MS = 2500
    }
}
