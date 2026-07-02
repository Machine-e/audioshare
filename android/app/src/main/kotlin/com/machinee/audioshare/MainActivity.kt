package com.machinee.audioshare

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingProjectionResult: MethodChannel.Result? = null
    private var pendingRuntimePermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestCapturePermission" -> requestCapturePermission(result)
                "startForegroundCaptureService" -> startCaptureService(call.arguments, result)
                "stopForegroundCaptureService" -> {
                    stopService(Intent(this, AudioCaptureService::class.java))
                    AudioCaptureService.clearProjectionData()
                    result.success(null)
                }
                "openBluetoothSettings" -> {
                    openSettingsIntent(Settings.ACTION_BLUETOOTH_SETTINGS)
                    result.success(null)
                }
                "openCastSettings" -> {
                    openCastSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    AudioCaptureService.statusSink = events
                }

                override fun onCancel(arguments: Any?) {
                    AudioCaptureService.statusSink = null
                }
            },
        )
    }

    private fun requestCapturePermission(result: MethodChannel.Result) {
        if (pendingProjectionResult != null || pendingRuntimePermissionResult != null) {
            result.error("permission_request_in_progress", "已有授权请求正在进行。", null)
            return
        }

        val missingPermissions = mutableListOf<String>()
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            missingPermissions.add(Manifest.permission.RECORD_AUDIO)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            missingPermissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        if (missingPermissions.isNotEmpty()) {
            pendingRuntimePermissionResult = result
            requestPermissions(missingPermissions.toTypedArray(), REQUEST_RUNTIME_PERMISSIONS)
            return
        }

        launchMediaProjectionRequest(result)
    }

    private fun startCaptureService(arguments: Any?, result: MethodChannel.Result) {
        if (AudioCaptureService.projectionData == null) {
            result.error(
                "missing_media_projection",
                "请先通过系统弹窗授权捕获系统播放音频。",
                null,
            )
            return
        }
        val args = arguments as? Map<*, *>
        if (args == null) {
            result.error("missing_capture_config", "缺少推流会话参数。", null)
            return
        }

        try {
            val intent = Intent(this, AudioCaptureService::class.java).apply {
                action = AudioCaptureService.ACTION_START
                putExtra(AudioCaptureService.EXTRA_HOST, args["host"] as? String ?: "")
                putExtra(AudioCaptureService.EXTRA_CONTROL_PORT, (args["controlPort"] as? Number)?.toInt() ?: 0)
                putExtra(AudioCaptureService.EXTRA_UDP_PORT, (args["udpPort"] as? Number)?.toInt() ?: 0)
                putExtra(AudioCaptureService.EXTRA_PAIRING_CODE, args["pairingCode"] as? String ?: "")
                putExtra(AudioCaptureService.EXTRA_SESSION_ID, (args["sessionId"] as? Number)?.toLong() ?: 0L)
                putExtra(AudioCaptureService.EXTRA_AUDIO_AUTH_KEY, args["audioAuthKey"] as? String ?: "")
                putExtra(AudioCaptureService.EXTRA_BITRATE_KBPS, (args["bitrateKbps"] as? Number)?.toInt() ?: 96)
                putExtra(AudioCaptureService.EXTRA_SAMPLE_RATE, (args["sampleRate"] as? Number)?.toInt() ?: 48_000)
                putExtra(AudioCaptureService.EXTRA_FRAME_MS, (args["frameMs"] as? Number)?.toInt() ?: 20)
                putExtra(AudioCaptureService.EXTRA_BUFFER_MS, (args["bufferMs"] as? Number)?.toInt() ?: 80)
                putExtra(AudioCaptureService.EXTRA_CHANNELS, (args["channels"] as? Number)?.toInt() ?: 2)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            result.success(null)
        } catch (error: RuntimeException) {
            result.error("foreground_service_start_failed", error.message, null)
        }
    }

    private fun launchMediaProjectionRequest(result: MethodChannel.Result) {
        pendingProjectionResult = result
        val projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(
            projectionManager.createScreenCaptureIntent(),
            REQUEST_MEDIA_PROJECTION,
        )
    }

    private fun openCastSettings() {
        val actions = listOf(
            "android.settings.CAST_SETTINGS",
            Settings.ACTION_WIFI_SETTINGS,
        )
        for (action in actions) {
            val intent = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                return
            }
        }
        openSettingsIntent(Settings.ACTION_SETTINGS)
    }

    private fun openSettingsIntent(action: String) {
        val intent = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (intent.resolveActivity(packageManager) != null) {
            startActivity(intent)
        } else {
            startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_RUNTIME_PERMISSIONS) return

        val result = pendingRuntimePermissionResult ?: return
        pendingRuntimePermissionResult = null
        val recordAudioIndex = permissions.indexOf(Manifest.permission.RECORD_AUDIO)
        val recordAudioGranted = if (recordAudioIndex >= 0) {
            grantResults.getOrNull(recordAudioIndex) == PackageManager.PERMISSION_GRANTED
        } else {
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        }

        if (!recordAudioGranted) {
            result.error("record_audio_denied", "录音权限被拒绝，无法捕获系统播放音频。", null)
            return
        }

        launchMediaProjectionRequest(result)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_MEDIA_PROJECTION) return

        val result = pendingProjectionResult ?: return
        pendingProjectionResult = null
        if (resultCode == Activity.RESULT_OK && data != null) {
            AudioCaptureService.setProjectionData(resultCode, data)
            result.success(true)
        } else {
            result.error("media_projection_denied", "系统音频捕获授权被取消。", null)
        }
    }

    companion object {
        private const val CHANNEL = "com.machinee.audioshare/audio_capture"
        private const val EVENTS_CHANNEL = "com.machinee.audioshare/audio_capture_events"
        private const val REQUEST_MEDIA_PROJECTION = 4201
        private const val REQUEST_RUNTIME_PERMISSIONS = 4202
    }
}
