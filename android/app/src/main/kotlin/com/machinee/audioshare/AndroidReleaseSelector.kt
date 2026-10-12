package com.machinee.audioshare

data class ReleaseAsset(val name: String, val url: String)
data class AppRelease(
    val tag: String,
    val assets: List<ReleaseAsset>,
    val draft: Boolean = false,
    val prerelease: Boolean = false,
)

// Pure selection logic: Windows-only releases are not Android update failures.
object AndroidReleaseSelector {
    private fun version(tag: String): List<Long>? {
        val match = Regex("^[vV]?(\\d+\\.\\d+\\.\\d+)(?:\\+[^ ]+)?$").matchEntire(tag)
            ?: return null
        return match.groupValues[1].split('.').map { it.toLongOrNull() ?: return null }
    }

    private fun compare(left: List<Long>, right: List<Long>): Int {
        for (i in left.indices) {
            val comparison = left[i].compareTo(right[i])
            if (comparison != 0) return comparison
        }
        return 0
    }

    fun select(releases: List<AppRelease>, current: String, abis: List<String>): Map<String, Any> {
        val currentVersion = requireNotNull(version(current)) { "无法识别当前应用版本" }
        val stable = releases.filter { !it.draft && !it.prerelease && version(it.tag) != null }
            .sortedWith { a, b -> compare(version(b.tag)!!, version(a.tag)!!) }
        val candidate = stable.firstNotNullOfOrNull { release ->
            val asset = release.assets.mapNotNull { asset ->
                val name = asset.name.lowercase()
                val url = runCatching { java.net.URI(asset.url) }.getOrNull()
                if (url?.scheme != "https" || url.host != "github.com" ||
                    !url.path.startsWith("/Machine-e/audioshare/releases/download/") ||
                    !name.endsWith(".apk") || name.contains("debug") ||
                    !(name.startsWith("audioshare") || name.startsWith("app-"))) return@mapNotNull null
                val knownAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86")
                val abi = knownAbis.firstOrNull { name.contains(it) }
                if (abi != null && abi !in abis) return@mapNotNull null
                // Unknown naming is not proof that an APK is universal.
                val rank = when {
                    name == "audioshare-android.apk" -> 0
                    name == "app-release.apk" || name.contains("universal") -> 1
                    abi != null -> 2 + abis.indexOf(abi)
                    Regex("audioshare(?:-android)?-v?\\d+\\.\\d+\\.\\d+\\.apk").matches(name) -> 10
                    else -> return@mapNotNull null
                }
                rank to asset
            }.minByOrNull { it.first }?.second
            asset?.let { release to it }
        }
        val latest = candidate?.first?.tag?.removePrefix("v")?.removePrefix("V") ?: ""
        val available = candidate != null && compare(version(latest)!!, currentVersion) > 0
        val newerWithoutApk = !available && stable.any { compare(version(it.tag)!!, currentVersion) > 0 }
        val message = when {
            candidate == null -> "发布页暂未提供适合此手机的 Android 安装包"
            available -> "发现新版本 $latest"
            newerWithoutApk -> "较新发布暂未提供适合此手机的 Android 安装包"
            else -> "当前没有可用的 Android 更新"
        }
        return mapOf(
            "available" to available, "currentVersion" to current,
            "latestVersion" to latest, "downloadUrl" to if (available) candidate!!.second.url else "",
            "message" to message,
        )
    }
}
