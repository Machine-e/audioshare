package com.machinee.audioshare

import org.junit.Assert.*
import org.junit.Test

class AndroidReleaseSelectorTest {
    private fun asset(name: String) = ReleaseAsset(name,
        "https://github.com/Machine-e/audioshare/releases/download/v1.0.0/$name")
    private fun select(vararg releases: AppRelease, current: String = "0.2.2") =
        AndroidReleaseSelector.select(releases.toList(), current, listOf("arm64-v8a", "armeabi-v7a"))

    @Test fun windowsOnlyReleaseIsNotAnExceptionOrUpToDateClaim() {
        val result = select(AppRelease("v0.1.0", listOf(asset("AudioShare-Windows.zip"))))
        assertEquals(false, result["available"])
        assertEquals("", result["downloadUrl"])
        assertTrue((result["message"] as String).contains("暂未提供"))
    }

    @Test fun fallsBackFromWindowsOnlyReleaseToNewestAndroidRelease() {
        val result = select(AppRelease("v0.4.0", emptyList()),
            AppRelease("v0.3.0", listOf(asset("app-release.apk"))))
        assertEquals(true, result["available"])
        assertEquals("0.3.0", result["latestVersion"])
    }

    @Test fun supportsCanonicalVersionedAndUniversalAssets() {
        for (name in listOf("AudioShare-Android.apk", "AudioShare-Android-v1.0.0.apk", "app-universal-release.apk")) {
            assertEquals(true, select(AppRelease("v1.0.0", listOf(asset(name))))["available"])
        }
    }

    @Test fun excludesDraftPrereleaseBadTagsAndOlderVersions() {
        val assets = listOf(asset("AudioShare-Android.apk"))
        val result = select(AppRelease("v4.0.0", assets, draft = true),
            AppRelease("v3.0.0", assets, prerelease = true),
            AppRelease("nightly", assets), AppRelease("v0.2.1", assets))
        assertEquals(false, result["available"])
        assertEquals("", result["downloadUrl"])
    }

    @Test fun matchesPhoneAbiAndRejectsOtherDownloads() {
        val result = select(AppRelease("v1.0.0", listOf(asset("app-x86_64-release.apk"),
            asset("app-arm64-v8a-release.apk"), asset("app-debug.apk"))))
        assertTrue((result["downloadUrl"] as String).endsWith("app-arm64-v8a-release.apk"))
        assertEquals(false, select(AppRelease("v1.0.0", listOf(asset("app-x86-release.apk"))))["available"])
        assertEquals(false, select(AppRelease("v1.0.0", listOf(ReleaseAsset("app-release.apk", "https://example.com/a.apk"))))["available"])
    }

    @Test fun comparesVersionsNumericallyAndDoesNotOfferDowngrades() {
        val assets = listOf(asset("app-release.apk"))
        assertEquals(true, select(AppRelease("v0.10.0", assets), current = "0.9.0")["available"])
        assertEquals(false, select(AppRelease("v0.2.2", assets))["available"])
        assertEquals(false, select(AppRelease("v0.2.2", assets), current = "0.2.2+4")["available"])
    }
}
