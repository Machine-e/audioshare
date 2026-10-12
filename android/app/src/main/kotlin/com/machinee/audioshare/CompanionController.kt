package com.machinee.audioshare

import android.Manifest
import android.app.StatusBarManager
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.media.MediaRouter2
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class CompanionController(
    private val activity: MainActivity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val adapter get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    private val seen = linkedMapOf<String, BluetoothDevice>()
    private var sink: EventChannel.EventSink? = null
    private var a2dp: BluetoothProfile? = null
    private var a2dpRequestPending = false
    private var a2dpProxyToken = 0
    private val a2dpObservations = mutableMapOf<String, A2dpObservation>()
    private var selected: String? = prefs.getString(LAST_DEVICE, null)
    private var socket: BluetoothSocket? = null
    private var generation = AtomicInteger()
    private var controlState = "idle"
    private var receiverMode: String? = null
    private var receiverTarget = "unknown"
    private var message = ""
    private var resumedOnce = false
    private var foreground = false
    private var destroyed = false
    private var discoveryToken = 0
    private var revision = 0L
    private var statusRetryToken = 0
    private var statusRetryAttempts = 0
    private var statusRetryPending = false
    private val observeMedia = object : Runnable {
        override fun run() {
            if (destroyed || !foreground) return
            refreshProfiles()
            emit()
            main.postDelayed(this, 2_000)
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent) {
            if (destroyed || !foreground) return
            if (!hasAccess() || !safeAdapterEnabled()) {
                stopDiscovery()
                closeControl("idle", "蓝牙权限已撤销或蓝牙已关闭")
                seen.clear()
                clearA2dpObservations()
                closeA2dpProxy()
                return
            }
            try { when (intent.action) {
                BluetoothAdapter.ACTION_STATE_CHANGED -> {
                    refreshProfiles()
                    if (controlState == "idle") selected?.let { id ->
                        safeBonded().firstOrNull { it.address == id }?.let(::connectControl)
                    }
                }
                BluetoothDevice.ACTION_FOUND -> intent.device()?.let { if (isComputer(it)) { seen[it.address] = it; rememberName(it) } }
                BluetoothDevice.ACTION_BOND_STATE_CHANGED -> intent.device()?.let {
                    if (isComputer(it)) { seen[it.address] = it; rememberName(it) }
                    if (it.address == selected && it.bondState == BluetoothDevice.BOND_BONDED) connectControl(it)
                    else if (it.address == selected && it.bondState == BluetoothDevice.BOND_NONE) closeControl("idle", "配对已取消或失败，请重试")
                }
                BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED -> {
                    val device = intent.device()
                    val state = intent.getIntExtra(BluetoothProfile.EXTRA_STATE, BluetoothProfile.STATE_DISCONNECTED)
                    device?.let { updateA2dpConnectionBroadcast(it.address, state) }
                    if (state == BluetoothProfile.STATE_CONNECTED && device?.address == selected) {
                        statusRetryAttempts = 0
                        scheduleStatusRetry()
                    }
                }
                BluetoothA2dp.ACTION_PLAYING_STATE_CHANGED -> {
                    val device = intent.device()
                    val state = intent.getIntExtra(BluetoothProfile.EXTRA_STATE, BluetoothA2dp.STATE_NOT_PLAYING)
                    device?.let { updateA2dpPlayingBroadcast(it.address, state) }
                }
                BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> Unit
            } } catch (_: SecurityException) { closeControl("idle", "蓝牙权限已撤销") }
            emit()
        }
    }

    init {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
        ContextCompat.registerReceiver(activity, receiver, IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED)
            addAction(BluetoothA2dp.ACTION_PLAYING_STATE_CHANGED)
        }, ContextCompat.RECEIVER_EXPORTED)
        handleIntent(activity.intent)
        refreshProfiles()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events; emit() }
    override fun onCancel(arguments: Any?) { sink = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "requestAccess" -> { requestAccess(); result.success(snapshot()) }
                "getSnapshot" -> result.success(snapshot())
                "startDiscovery" -> { startDiscovery(); result.success(snapshot()) }
                "stopDiscovery" -> { stopDiscovery(); result.success(snapshot()) }
                "selectDevice" -> { select(call.argument("deviceId")); result.success(snapshot()) }
                "setFavorite" -> { setFavorite(call.argument("deviceId"), call.argument<Boolean>("favorite") == true); result.success(snapshot()) }
                "disconnectControl" -> { cancelStatusRetries(); closeControl("idle", "状态通道已关闭，蓝牙音频不受影响"); result.success(snapshot()) }
                "retryStatus" -> { retryStatus(manual = true); result.success(snapshot()) }
                "showOutputSwitcher" -> result.success(showOutputSwitcher())
                "pinShortcut" -> result.success(pinShortcut(call.argument("deviceId")))
                "addQuickTile" -> result.success(addQuickTile())
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            message = "需要蓝牙权限，请授权后重试"; emit(); result.error("bluetooth_permission", message, null)
        } catch (e: Exception) {
            result.error("android_error", e.message ?: "Android operation failed", e.javaClass.simpleName)
        }
    }

    private fun requestAccess() {
        if (!hasAccess()) activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN), ACCESS_REQUEST)
        else if (!adapter.isEnabled) activity.startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
    }

    fun onRequestPermissionsResult(requestCode: Int) {
        if (requestCode != ACCESS_REQUEST) return
        if (hasAccess() && !adapter.isEnabled) activity.startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
        refreshProfiles()
        if (foreground && hasAccess()) selected?.let { id -> safeBonded().firstOrNull { it.address == id }?.let(::connectControl) }
        emit()
    }

    private fun startDiscovery() {
        if (!foreground || !hasAccess() || !safeAdapterEnabled()) { message = "请先授予蓝牙权限并开启蓝牙"; return }
        stopDiscovery()
        val token = ++discoveryToken
        if (!adapter.startDiscovery()) { message = "无法开始扫描，请稍后重试"; emit(); return }
        main.postDelayed({ if (!destroyed && foreground && token == discoveryToken) { stopDiscovery(); emit() } }, 12_000)
        message = "正在查找附近的电脑"
    }
    private fun stopDiscovery() { discoveryToken++; try { if (hasAccess() && adapter.isDiscovering) adapter.cancelDiscovery() } catch (_: Exception) {} }

    private fun select(id: String?) {
        require(!id.isNullOrBlank()) { "deviceId is required" }
        if (!foreground || !hasAccess() || !safeAdapterEnabled()) { message = "请先授予蓝牙权限并开启蓝牙"; return }
        stopDiscovery()
        cancelStatusRetries()
        closeControl("idle", "")
        val device = seen[id] ?: safeBonded().firstOrNull { it.address == id }
        if (device == null || !isComputer(device)) { message = "未找到可用的电脑设备"; return }
        selected = id; remember(id); emit()
        if (device.bondState != BluetoothDevice.BOND_BONDED) {
            message = if (device.createBond()) "请在系统对话框中确认配对" else "无法开始配对，请重试"
            emit()
        } else connectControl(device)
    }

    private fun connectControl(device: BluetoothDevice) {
        if (destroyed || !foreground || !hasAccess() || !safeAdapterEnabled() || controlState == "connecting" || controlState == "connected") return
        stopDiscovery()
        refreshProfiles()
        closeControl("connecting", "正在连接电脑状态服务")
        val mine = generation.incrementAndGet()
        receiverMode = null; receiverTarget = "unknown"; emit()
        executor.execute {
            if (generation.get() != mine) return@execute
            var candidate: BluetoothSocket? = null
            var stage = "连接"
            try {
                candidate = device.createRfcommSocketToServiceRecord(STATUS_UUID)
                main.post {
                    if (destroyed || !foreground || generation.get() != mine) try { candidate.close() } catch (_: Exception) {}
                    else socket = candidate
                }
                main.postDelayed({ if (generation.get() == mine && controlState == "connecting") try { candidate.close() } catch (_: Exception) {} }, 12_000)
                candidate.connect()
                main.post { if (!destroyed && foreground && generation.get() == mine && socket === candidate) { controlState = "connected"; statusRetryAttempts = 0; statusRetryPending = false; message = "控制状态已连接"; emit() } }
                stage = "读取状态"
                readFrames(candidate, mine)
            } catch (e: Exception) {
                val diagnostic = statusDiagnostic(stage, e)
                main.post { if (!destroyed && foreground && generation.get() == mine && (socket == null || socket === candidate)) { closeControl("unavailable", diagnostic); scheduleStatusRetry() } }
            } finally {
                try { candidate?.close() } catch (_: Exception) {}
                main.post { if (socket === candidate) socket = null }
            }
        }
    }

    private fun readFrames(s: BluetoothSocket, mine: Int) {
        val input = s.inputStream
        val heartbeat = AtomicInteger()
        while (generation.get() == mine) {
            val expected = heartbeat.incrementAndGet()
            main.postDelayed({
                if (generation.get() == mine && heartbeat.get() == expected) try { s.close() } catch (_: Exception) {}
            }, 5_000)
            val bytes = ByteArrayOutputStream()
            while (true) {
                val value = input.read()
                if (value < 0) throw IllegalStateException("closed")
                if (value == 10) break
                if (bytes.size() >= 512) throw IllegalArgumentException("frame too long")
                bytes.write(value)
            }
            val frame = TargetFrameParser.parse(bytes.toByteArray())
            heartbeat.incrementAndGet()
            main.post { if (!destroyed && foreground && generation.get() == mine) { receiverMode = frame.first; receiverTarget = frame.second; emit() } }
        }
    }

    private fun closeControl(state: String, text: String) {
        generation.incrementAndGet(); try { socket?.close() } catch (_: Exception) {}; socket = null
        controlState = state; receiverMode = null; receiverTarget = "unknown"; message = text; emit()
    }

    private fun retryStatus(manual: Boolean = false) {
        if (destroyed || !foreground || !hasAccess() || !safeAdapterEnabled() ||
            controlState == "connecting" || controlState == "connected") return
        if (manual) {
            statusRetryToken++
            statusRetryAttempts = 0
            statusRetryPending = false
            closeA2dpProxy()
            refreshProfiles()
        }
        val id = selected ?: return
        val device = safeBonded().firstOrNull { it.address == id && it.bondState == BluetoothDevice.BOND_BONDED } ?: return
        connectControl(device)
    }

    private fun scheduleStatusRetry() {
        val id = selected ?: return
        if (destroyed || !foreground || controlState == "connected" || controlState == "connecting" ||
            statusRetryPending || statusRetryAttempts >= MAX_STATUS_RETRIES ||
            safeBonded().none { it.address == id }) return
        val token = statusRetryToken
        val delay = STATUS_RETRY_DELAYS_MS[statusRetryAttempts++]
        statusRetryPending = true
        main.postDelayed({
            if (token != statusRetryToken) return@postDelayed
            statusRetryPending = false
            // Status discovery is useful before A2DP connects. Gating retries
            // on a media connection leaves the first selection permanently
            // unavailable when the PC service is still starting.
            if (!destroyed && foreground && selected == id) retryStatus()
        }, delay)
    }

    private fun cancelStatusRetries() {
        statusRetryToken++
        statusRetryAttempts = 0
        statusRetryPending = false
    }

    private fun statusDiagnostic(stage: String, error: Exception): String {
        val kind = when (error) {
            is java.net.SocketTimeoutException -> "超时"
            is SecurityException -> "权限不足"
            is IllegalArgumentException -> "帧格式错误"
            else -> error.javaClass.simpleName.take(32)
        }
        return "RFCOMM 状态服务${stage}失败（$kind）；蓝牙音频连接状态不受此结果判定"
    }

    fun onStop() { foreground = false; main.removeCallbacks(observeMedia); statusRetryToken++; statusRetryPending = false; statusRetryAttempts = 0; clearA2dpObservations(); stopDiscovery(); closeControl("idle", "应用进入后台，控制连接已关闭"); resumedOnce = false }
    fun onResume() {
        foreground = true
        main.removeCallbacks(observeMedia)
        main.postDelayed(observeMedia, 2_000)
        clearA2dpObservations()
        refreshProfiles()
        if (!resumedOnce) { resumedOnce = true; selected?.let { id -> if (hasAccess()) safeBonded().firstOrNull { it.address == id }?.let(::connectControl) } }
        emit()
    }
    fun destroy() { destroyed = true; foreground = false; main.removeCallbacks(observeMedia); stopDiscovery(); closeControl("idle", ""); try { activity.unregisterReceiver(receiver) } catch (_: Exception) {}; closeA2dpProxy(); executor.shutdownNow() }

    fun handleIntent(intent: Intent?) {
        val id = intent?.getStringExtra(EXTRA_DEVICE) ?: return
        intent.removeExtra(EXTRA_DEVICE)
        if (!BluetoothAdapter.checkBluetoothAddress(id)) return
        if (foreground && hasAccess()) select(id) else {
            selected = id
            message = if (hasAccess()) "" else "请授予蓝牙权限以使用这台电脑"
            emit()
        }
    }

    private fun refreshProfiles() {
        if (!hasAccess() || !safeAdapterEnabled()) { clearA2dpObservations(); closeA2dpProxy(); return }
        if (a2dp != null || a2dpRequestPending) return
        a2dpRequestPending = true
        val token = ++a2dpProxyToken
        val accepted = try { adapter.getProfileProxy(activity, object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                if (token != a2dpProxyToken || destroyed || !hasAccess() || !safeAdapterEnabled()) {
                    try { adapter.closeProfileProxy(profile, proxy) } catch (_: Exception) {}
                    return
                }
                a2dpRequestPending = false
                a2dp = proxy
                sampleA2dpProxy(proxy)
                scheduleStatusRetry()
                emit()
            }
            override fun onServiceDisconnected(profile: Int) {
                if (token != a2dpProxyToken) return
                a2dpRequestPending = false
                a2dp = null
                clearA2dpObservations()
                if (!destroyed) emit()
            }
        }, BluetoothProfile.A2DP) } catch (_: Exception) { false }
        if (!accepted && token == a2dpProxyToken) a2dpRequestPending = false
    }

    private fun closeA2dpProxy() {
        a2dpProxyToken++
        clearA2dpObservations()
        val proxy = a2dp
        a2dp = null
        a2dpRequestPending = false
        if (proxy != null) try { adapter.closeProfileProxy(BluetoothProfile.A2DP, proxy) } catch (_: Exception) {}
    }

    private fun clearA2dpObservations() = a2dpObservations.clear()

    private fun updateA2dpConnectionBroadcast(id: String, state: Int) {
        val observation = a2dpObservations.getOrPut(id) { A2dpObservation() }
        observation.connectionUntil = SystemClock.elapsedRealtime() + 1_500
        when (state) {
            BluetoothProfile.STATE_CONNECTED -> observation.connected = true
            BluetoothProfile.STATE_DISCONNECTED -> {
                observation.connected = false
                observation.playing = false
                observation.playingUntil = observation.connectionUntil
                if (id == selected) { statusRetryToken++; statusRetryPending = false; statusRetryAttempts = 0 }
            }
        }
    }

    private fun updateA2dpPlayingBroadcast(id: String, state: Int) {
        val observation = a2dpObservations.getOrPut(id) { A2dpObservation() }
        observation.playingUntil = SystemClock.elapsedRealtime() + 1_500
        when (state) {
            BluetoothA2dp.STATE_PLAYING -> { observation.playing = true; observation.connected = true; observation.connectionUntil = observation.playingUntil }
            BluetoothA2dp.STATE_NOT_PLAYING -> observation.playing = false
        }
    }

    private fun sampleA2dpProxy(proxy: BluetoothProfile) {
        if (!foreground || !hasAccess() || !safeAdapterEnabled()) { clearA2dpObservations(); return }
        val typed = proxy as? BluetoothA2dp ?: return
        val connectedIds = try { proxy.connectedDevices.mapTo(mutableSetOf()) { it.address } } catch (_: SecurityException) { clearA2dpObservations(); return }
        seen.values.forEach { device ->
            val id = try { device.address } catch (_: SecurityException) { return@forEach }
            val connected = try { id in connectedIds || proxy.getConnectionState(device) == BluetoothProfile.STATE_CONNECTED } catch (_: SecurityException) { null }
            val playing = try { typed.isA2dpPlaying(device) } catch (_: SecurityException) { null }
            val observation = a2dpObservations.getOrPut(id) { A2dpObservation() }
            // Broadcasts win only briefly; never latch a prior true indefinitely.
            val now = SystemClock.elapsedRealtime()
            if (now >= observation.connectionUntil) observation.connected = connected
            if (now >= observation.playingUntil) observation.playing = playing
            if (observation.playing == true && now >= observation.connectionUntil) observation.connected = true
        }
    }

    private fun snapshot(): Map<String, Any?> {
        val access = hasAccess()
        val enabled = access && safeAdapterEnabled()
        if (!enabled && controlState != "idle") {
            generation.incrementAndGet()
            try { socket?.close() } catch (_: Exception) {}
            socket = null
            controlState = "idle"
            receiverMode = null
            receiverTarget = "unknown"
        }
        val bonded = if (enabled) safeBonded().filter(::isComputer) else emptyList()
        if (!enabled) { seen.clear(); clearA2dpObservations() }
        bonded.forEach { seen[it.address] = it; rememberName(it) }
        a2dp?.let(::sampleA2dpProxy)
        val recent = recentIds()
        val devices = seen.entries.map { (knownId, d) ->
            try {
                val id = d.address
                val observation = a2dpObservations[id]
                val a2dpConnected = observation?.connected == true
                val a2dpStateKnown = observation?.connected != null
                mapOf(
                    "id" to id, "name" to (safeName(d) ?: savedName(id) ?: "电脑"),
                    "bonded" to (d.bondState == BluetoothDevice.BOND_BONDED), "bonding" to (d.bondState == BluetoothDevice.BOND_BONDING),
                    "a2dpConnected" to a2dpConnected, "a2dpStateKnown" to a2dpStateKnown,
                    "a2dpPlaying" to (observation?.playing == true),
                    "favorite" to prefs.getBoolean("favorite_$id", false), "recent" to recent.contains(id))
            } catch (_: SecurityException) {
                mapOf("id" to knownId, "name" to (savedName(knownId) ?: "电脑"), "bonded" to false, "bonding" to false,
                    "a2dpConnected" to false, "a2dpStateKnown" to false,
                    "a2dpPlaying" to false,
                    "favorite" to prefs.getBoolean("favorite_$knownId", false), "recent" to recent.contains(knownId))
            }
        }.sortedWith(compareByDescending<Map<String, Any?>> { it["favorite"] == true }
            .thenBy { recent.indexOf(it["id"]).let { index -> if (index < 0) Int.MAX_VALUE else index } }
            .thenBy { it["name"] as String })
        revision++
        return mapOf(
            "permission" to access, "bluetoothEnabled" to enabled,
            "discovering" to (enabled && try { adapter.isDiscovering } catch (_: SecurityException) { false }),
            "devices" to devices,
            "selectedDeviceId" to selected, "controlState" to controlState,
            "receiverMode" to receiverMode, "receiverTarget" to receiverTarget, "message" to message,
            "outputSwitcherSupported" to (Build.VERSION.SDK_INT >= 34),
            "revision" to revision,
        )
    }

    private fun emit() {
        if (destroyed) return
        if (Looper.myLooper() == Looper.getMainLooper()) sink?.success(snapshot())
        else main.post { if (!destroyed) sink?.success(snapshot()) }
    }
    private fun hasAccess() = ContextCompat.checkSelfPermission(activity, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED && ContextCompat.checkSelfPermission(activity, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
    private fun safeAdapterEnabled() = try { adapter.isEnabled } catch (_: Exception) { false }
    private fun safeBonded() = try { adapter.bondedDevices.toList() } catch (_: Exception) { emptyList() }
    private fun isComputer(d: BluetoothDevice) = try {
        d.bluetoothClass?.majorDeviceClass == BluetoothClass.Device.Major.COMPUTER ||
            recentIds().contains(d.address) || d.uuids?.contains(AUDIO_SINK_UUID) == true
    } catch (_: SecurityException) { false }
    private fun safeName(d: BluetoothDevice) = try { d.name } catch (_: SecurityException) { null }
    private fun Intent.device(): BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java) else @Suppress("DEPRECATION") getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
    private fun recentIds() = prefs.getString(RECENTS, "")!!.split(',').filter(String::isNotBlank)
    private fun remember(id: String) { prefs.edit().putString(RECENTS, (listOf(id) + recentIds().filter { it != id }).take(5).joinToString(",")).putString(LAST_DEVICE, id).apply() }
    private fun rememberName(device: BluetoothDevice) { safeName(device)?.takeIf(String::isNotBlank)?.let { prefs.edit().putString("name_${device.address}", it).apply() } }
    private fun savedName(id: String) = prefs.getString("name_$id", null)
    private fun setFavorite(id: String?, favorite: Boolean) { require(!id.isNullOrBlank()); prefs.edit().putBoolean("favorite_$id", favorite).apply(); emit() }

    private fun showOutputSwitcher(): Boolean = if (Build.VERSION.SDK_INT >= 34) MediaRouter2.getInstance(activity).showSystemOutputSwitcher() else { message = "请从正在播放 App 的通知中选择媒体输出"; emit(); false }
    private fun pinShortcut(id: String?): Boolean {
        if (id.isNullOrBlank()) return false
        val manager = activity.getSystemService(ShortcutManager::class.java)
        if (!manager.isRequestPinShortcutSupported) return false
        val launch = Intent(activity, MainActivity::class.java).setAction(Intent.ACTION_VIEW).putExtra(EXTRA_DEVICE, id).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return manager.requestPinShortcut(ShortcutInfo.Builder(activity, "device_$id").setShortLabel(seen[id]?.let(::safeName) ?: "AudioShare PC").setIcon(Icon.createWithResource(activity, com.machinee.audioshare.R.mipmap.ic_launcher)).setIntent(launch).build(), null)
    }
    private fun addQuickTile(): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        activity.getSystemService(StatusBarManager::class.java).requestAddTileService(ComponentName(activity, AudioShareTileService::class.java), "AudioShare", Icon.createWithResource(activity, com.machinee.audioshare.R.drawable.ic_audioshare_monochrome), activity.mainExecutor) {}
        return true
    }

    companion object {
        const val PREFS = "companion"; const val LAST_DEVICE = "last_device"; const val EXTRA_DEVICE = "companion_device"
        private const val RECENTS = "recent_devices"
        private const val METHOD_CHANNEL = "com.machinee.audioshare/companion"
        private const val EVENT_CHANNEL = "com.machinee.audioshare/companion_events"
        private const val ACCESS_REQUEST = 4101
        private const val MAX_STATUS_RETRIES = 3
        private val STATUS_RETRY_DELAYS_MS = longArrayOf(1_500, 3_000, 5_000)
        private val STATUS_UUID = UUID.fromString("8fa6bca1-bd4c-4bde-bd1c-c7b45e05a711")
        private val AUDIO_SINK_UUID = ParcelUuid(UUID.fromString("0000110b-0000-1000-8000-00805f9b34fb"))
    }
}

private data class A2dpObservation(var connected: Boolean? = null, var playing: Boolean? = null,
    var connectionUntil: Long = 0, var playingUntil: Long = 0)

internal object TargetFrameParser {
    private val modes = setOf("stopped", "starting", "waitingForRoute", "opened", "disconnected", "error")
    private val targets = setOf("thisPhone", "otherPhone", "unknown")

    fun parse(bytes: ByteArray): Pair<String, String> {
        require(bytes.size <= 512) { "frame too long" }
        val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        val json = JSONObject(decoder.decode(ByteBuffer.wrap(bytes)).toString())
        require(json.length() == 3 && json.has("v") && json.has("mode") && json.has("target")) { "invalid frame fields" }
        require(json.get("v") is Int && json.getInt("v") == 1) { "invalid frame version" }
        require(json.get("mode") is String && json.get("target") is String) { "invalid frame types" }
        val mode = json.getString("mode")
        val target = json.getString("target")
        require(mode.length <= 32 && target.length <= 32 && mode in modes && target in targets) { "invalid frame values" }
        return mode to target
    }
}
