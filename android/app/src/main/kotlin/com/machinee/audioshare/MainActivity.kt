package com.machinee.audioshare

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startForegroundCaptureService" -> {
                    startService(Intent(this, AudioCaptureService::class.java))
                    result.success(null)
                }
                "stopForegroundCaptureService" -> {
                    stopService(Intent(this, AudioCaptureService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        private const val CHANNEL = "com.machinee.audioshare/audio_capture"
    }
}
