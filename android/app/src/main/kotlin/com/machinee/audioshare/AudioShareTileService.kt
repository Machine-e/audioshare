package com.machinee.audioshare

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService

class AudioShareTileService : TileService() {
    override fun onClick() {
        super.onClick()
        val deviceId = getSharedPreferences(CompanionController.PREFS, MODE_PRIVATE)
            .getString(CompanionController.LAST_DEVICE, null)
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(CompanionController.EXTRA_DEVICE, deviceId)
        }
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
