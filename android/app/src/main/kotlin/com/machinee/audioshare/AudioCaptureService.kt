package com.machinee.audioshare

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioManager
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.thread

class AudioCaptureService : Service() {
    private var mediaProjection: MediaProjection? = null
    @Volatile
    private var isCapturing = false
    private var captureThread: Thread? = null
    private var audioRecord: AudioRecord? = null
    private var udpSocket: DatagramSocket? = null
    private var projectionCallback: MediaProjection.Callback? = null
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var audioFocusGranted = false

    private var mediaProjectionAuthorized = false
    private var audioRecordCapturing = false
    private var opusEncoding = false
    private var pcmFramesCaptured = 0L
    private var opusFramesEncoded = 0L
    private var udpPacketsSent = 0L
    private var sendErrors = 0L
    private var zeroFrames = 0L
    private var readErrors = 0L
    private var underruns = 0L
    private var lastMessage = "等待启动"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val resultCode = projectionResultCode
        val data = projectionData
        if (resultCode == null || data == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        ensureChannel()
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (_: RuntimeException) {
            stopSelf()
            return START_NOT_STICKY
        }

        if (mediaProjection == null) {
            mediaProjection = try {
                val projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                projectionManager.getMediaProjection(resultCode, data)
            } catch (_: SecurityException) {
                null
            }
        }

        val projection = mediaProjection
        if (projection == null) {
            publishStatus("MediaProjection 授权不可用")
            stopSelf()
            return START_NOT_STICKY
        }

        mediaProjectionAuthorized = true
        startCaptureLoop(projection, CaptureConfig.fromIntent(intent))
        return START_STICKY
    }

    override fun onDestroy() {
        stopCaptureLoop("捕获服务已停止")
        projectionCallback?.let { mediaProjection?.unregisterCallback(it) }
        projectionCallback = null
        mediaProjection?.stop()
        mediaProjection = null
        super.onDestroy()
        clearProjectionData()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "AudioShare streaming",
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("AudioShare")
            .setContentText("正在推送系统播放音频")
            .setOngoing(true)
            .build()
    }

    private fun startCaptureLoop(projection: MediaProjection, config: CaptureConfig) {
        if (isCapturing) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            publishStatus("Android 10 以下不支持系统播放音频捕获")
            stopSelf()
            return
        }
        if (config.host.isBlank() || config.udpPort !in 1..65535) {
            publishStatus("Windows UDP 目标无效")
            stopSelf()
            return
        }

        requestBestEffortAudioFocus()
        projectionCallback = object : MediaProjection.Callback() {
            override fun onStop() {
                stopCaptureLoop("系统音频捕获授权已撤销")
                stopSelf()
            }
        }.also { projection.registerCallback(it, null) }

        isCapturing = true
        publishStatus("正在创建 AudioRecord 播放捕获")
        captureThread = thread(
            name = "AudioShareCapture",
            isDaemon = true,
        ) {
            runCaptureLoop(projection, config)
        }
    }

    private fun runCaptureLoop(projection: MediaProjection, config: CaptureConfig) {
        val channelMask = if (config.channels == 1) {
            AudioFormat.CHANNEL_IN_MONO
        } else {
            AudioFormat.CHANNEL_IN_STEREO
        }
        val bytesPerFrame = config.channels * BYTES_PER_SAMPLE
        val samplesPerChannel = config.sampleRate * config.frameMs / 1000
        val frameBytes = samplesPerChannel * bytesPerFrame
        val minBufferBytes = AudioRecord.getMinBufferSize(
            config.sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBufferBytes <= 0) {
            readErrors += 1
            publishStatus("AudioRecord 不支持当前音频格式")
            stopSelf()
            return
        }

        val bufferBytes = maxOf(minBufferBytes, frameBytes * maxOf(2, config.bufferMs / config.frameMs))
        val captureConfig = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val audioFormat = AudioFormat.Builder()
            .setSampleRate(config.sampleRate)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(channelMask)
            .build()

        var opusEncoder: AndroidOpusEncoder? = null
        try {
            val record = AudioRecord.Builder()
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(bufferBytes)
                .setAudioPlaybackCaptureConfig(captureConfig)
                .build()
            audioRecord = record
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                readErrors += 1
                publishStatus("AudioRecord 初始化失败")
                stopSelf()
                return
            }

            udpSocket = DatagramSocket()
            opusEncoder = try {
                AndroidOpusEncoder(config)
            } catch (error: Exception) {
                readErrors += 1
                publishStatus("设备不支持 Android Opus 编码：${error.message}")
                stopSelf()
                return
            }
            opusEncoding = true
            val remoteAddress = InetAddress.getByName(config.host)
            val authKey = config.audioAuthKey.toByteArray(Charsets.UTF_8)
            var sequence = 0L
            var presentationTimeUs = 0L
            val frame = ByteArray(frameBytes)

            record.startRecording()
            audioRecordCapturing = true
            publishStatus("AudioRecord 正在读取系统播放音频")

            while (isCapturing) {
                var offset = 0
                while (offset < frame.size && isCapturing) {
                    val read = record.read(frame, offset, frame.size - offset)
                    when {
                        read > 0 -> offset += read
                        read == 0 -> {
                            zeroFrames += 1
                            Thread.sleep(2)
                        }
                        else -> {
                            readErrors += 1
                            publishStatus("AudioRecord 读取错误：$read")
                            break
                        }
                    }
                }
                if (!isCapturing || offset < frame.size) continue

                if (frame.all { it == 0.toByte() }) {
                    zeroFrames += 1
                    if (zeroFrames == 1L || zeroFrames % 50L == 0L) {
                        publishStatus("捕获到静音帧，源应用可能禁止播放捕获")
                    }
                    continue
                }

                pcmFramesCaptured += 1
                val payload = opusEncoder.encode(frame, presentationTimeUs)
                presentationTimeUs += config.frameMs * 1000L
                if (payload == null) {
                    underruns += 1
                    continue
                }
                opusFramesEncoded += 1
                val packet = encodeAudioPacket(
                    sessionId = config.sessionId,
                    sequence = sequence++,
                    timestampMs = System.currentTimeMillis(),
                    payload = payload,
                    key = authKey,
                )
                try {
                    udpSocket?.send(
                        DatagramPacket(packet, packet.size, remoteAddress, config.udpPort),
                    )
                    udpPacketsSent += 1
                    if (udpPacketsSent == 1L || udpPacketsSent % 50L == 0L) {
                        publishStatus("已发送 $udpPacketsSent 个 UDP 音频包")
                    }
                } catch (error: Exception) {
                    sendErrors += 1
                    publishStatus("UDP 发送失败：${error.message}")
                }
            }
        } catch (error: Exception) {
            readErrors += 1
            publishStatus("系统音频捕获失败：${error.message}")
            stopSelf()
        } finally {
            opusEncoder?.close()
            releaseAudioResources()
        }
    }

    private fun stopCaptureLoop(message: String) {
        isCapturing = false
        publishStatus(message)
        releaseAudioResources()
        captureThread?.interrupt()
        captureThread = null
    }

    private fun releaseAudioResources() {
        audioRecordCapturing = false
        opusEncoding = false
        try {
            audioRecord?.stop()
        } catch (_: IllegalStateException) {
        }
        audioRecord?.release()
        audioRecord = null
        udpSocket?.close()
        udpSocket = null
        abandonAudioFocus()
    }

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                publishStatus("音频焦点已丢失；只能暂停 AudioShare 自有播放源")
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                publishStatus()
            }
        }
    }

    private fun requestBestEffortAudioFocus() {
        val manager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager = manager
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val focusAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(focusAttributes)
                .setOnAudioFocusChangeListener(focusChangeListener, mainHandler)
                .build()
            audioFocusRequest = request
            manager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(
                focusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
            )
        }
        audioFocusGranted = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (!audioFocusGranted) {
            publishStatus("音频焦点请求被拒绝，本机外放控制取决于源应用")
        }
    }

    private fun abandonAudioFocus() {
        val manager = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { manager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            manager.abandonAudioFocus(focusChangeListener)
        }
        audioFocusRequest = null
        audioFocusGranted = false
        audioManager = null
    }

    private fun encodeAudioPacket(
        sessionId: Long,
        sequence: Long,
        timestampMs: Long,
        payload: ByteArray,
        key: ByteArray,
    ): ByteArray {
        val headerLength = 4 + 2 + 8 + 8 + 8 + 2
        val body = ByteBuffer.allocate(headerLength + payload.size)
            .order(ByteOrder.BIG_ENDIAN)
            .put(AUDIO_MAGIC)
            .putShort(PROTOCOL_VERSION.toShort())
            .putLong(sessionId)
            .putLong(sequence)
            .putLong(timestampMs)
            .putShort(payload.size.toShort())
            .put(payload)
            .array()
        val tag = hmacSha256(key, body)
        return ByteBuffer.allocate(body.size + AUTH_TAG_LEN)
            .put(body)
            .put(tag, 0, AUTH_TAG_LEN)
            .array()
    }

    private fun hmacSha256(key: ByteArray, bytes: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(bytes)
    }

    private fun publishStatus(message: String = lastMessage) {
        lastMessage = message
        mainHandler.post {
            statusSink?.success(mapOf(
                "captureActive" to isCapturing,
                "mediaProjectionAuthorized" to mediaProjectionAuthorized,
                "audioRecordCapturing" to audioRecordCapturing,
                "opusEncoding" to opusEncoding,
                "pcmFramesCaptured" to pcmFramesCaptured,
                "opusFramesEncoded" to opusFramesEncoded,
                "udpPacketsSent" to udpPacketsSent,
                "sendErrors" to sendErrors,
                "zeroFrames" to zeroFrames,
                "readErrors" to readErrors,
                "underruns" to underruns,
                "lastMessage" to message,
            ))
        }
    }

    private class AndroidOpusEncoder(private val config: CaptureConfig) {
        private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
        private val bufferInfo = MediaCodec.BufferInfo()

        init {
            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_OPUS,
                config.sampleRate,
                config.channels,
            )
            format.setInteger(MediaFormat.KEY_BIT_RATE, config.bitrateKbps * 1000)
            format.setInteger(
                MediaFormat.KEY_MAX_INPUT_SIZE,
                config.sampleRate * config.channels * BYTES_PER_SAMPLE * config.frameMs / 1000,
            )
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
        }

        fun encode(pcm: ByteArray, presentationTimeUs: Long): ByteArray? {
            val inputIndex = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
            if (inputIndex < 0) return null
            val inputBuffer = codec.getInputBuffer(inputIndex) ?: return null
            inputBuffer.clear()
            inputBuffer.put(pcm)
            codec.queueInputBuffer(inputIndex, 0, pcm.size, presentationTimeUs, 0)

            val chunks = mutableListOf<ByteArray>()
            while (true) {
                val outputIndex = codec.dequeueOutputBuffer(bufferInfo, CODEC_TIMEOUT_US)
                when {
                    outputIndex >= 0 -> {
                        if (
                            bufferInfo.size > 0 &&
                            bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                        ) {
                            val outputBuffer = codec.getOutputBuffer(outputIndex)
                            if (outputBuffer != null) {
                                outputBuffer.position(bufferInfo.offset)
                                outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                                val chunk = ByteArray(bufferInfo.size)
                                outputBuffer.get(chunk)
                                chunks.add(chunk)
                            }
                        }
                        codec.releaseOutputBuffer(outputIndex, false)
                    }
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> continue
                    else -> break
                }
            }

            if (chunks.isEmpty()) return null
            if (chunks.size == 1) return chunks.first()
            val totalSize = chunks.sumOf { it.size }
            val combined = ByteArray(totalSize)
            var offset = 0
            for (chunk in chunks) {
                chunk.copyInto(combined, offset)
                offset += chunk.size
            }
            return combined
        }

        fun close() {
            try {
                codec.stop()
            } catch (_: IllegalStateException) {
            }
            codec.release()
        }
    }

    data class CaptureConfig(
        val host: String,
        val controlPort: Int,
        val udpPort: Int,
        val pairingCode: String,
        val sessionId: Long,
        val audioAuthKey: String,
        val bitrateKbps: Int,
        val sampleRate: Int,
        val frameMs: Int,
        val bufferMs: Int,
        val channels: Int,
    ) {
        companion object {
            fun fromIntent(intent: Intent?): CaptureConfig = CaptureConfig(
                host = intent?.getStringExtra(EXTRA_HOST).orEmpty(),
                controlPort = intent?.getIntExtra(EXTRA_CONTROL_PORT, 0) ?: 0,
                udpPort = intent?.getIntExtra(EXTRA_UDP_PORT, 0) ?: 0,
                pairingCode = intent?.getStringExtra(EXTRA_PAIRING_CODE).orEmpty(),
                sessionId = intent?.getLongExtra(EXTRA_SESSION_ID, 0L) ?: 0L,
                audioAuthKey = intent?.getStringExtra(EXTRA_AUDIO_AUTH_KEY).orEmpty(),
                bitrateKbps = intent?.getIntExtra(EXTRA_BITRATE_KBPS, 96) ?: 96,
                sampleRate = intent?.getIntExtra(EXTRA_SAMPLE_RATE, 48_000) ?: 48_000,
                frameMs = intent?.getIntExtra(EXTRA_FRAME_MS, 20) ?: 20,
                bufferMs = intent?.getIntExtra(EXTRA_BUFFER_MS, 80) ?: 80,
                channels = intent?.getIntExtra(EXTRA_CHANNELS, 2)?.coerceIn(1, 2) ?: 2,
            )
        }
    }

    companion object {
        const val ACTION_START = "com.machinee.audioshare.action.START_CAPTURE"
        const val EXTRA_HOST = "host"
        const val EXTRA_CONTROL_PORT = "controlPort"
        const val EXTRA_UDP_PORT = "udpPort"
        const val EXTRA_PAIRING_CODE = "pairingCode"
        const val EXTRA_SESSION_ID = "sessionId"
        const val EXTRA_AUDIO_AUTH_KEY = "audioAuthKey"
        const val EXTRA_BITRATE_KBPS = "bitrateKbps"
        const val EXTRA_SAMPLE_RATE = "sampleRate"
        const val EXTRA_FRAME_MS = "frameMs"
        const val EXTRA_BUFFER_MS = "bufferMs"
        const val EXTRA_CHANNELS = "channels"
        private const val CHANNEL_ID = "audioshare_streaming"
        private const val NOTIFICATION_ID = 1001
        private const val BYTES_PER_SAMPLE = 2
        private const val PROTOCOL_VERSION = 1
        private const val AUTH_TAG_LEN = 16
        private const val CODEC_TIMEOUT_US = 10_000L
        private val AUDIO_MAGIC = byteArrayOf(0x41, 0x53, 0x48, 0x31)
        private val mainHandler = Handler(Looper.getMainLooper())

        @Volatile
        var statusSink: EventChannel.EventSink? = null

        var projectionResultCode: Int? = null
            private set
        var projectionData: Intent? = null
            private set

        fun setProjectionData(resultCode: Int, data: Intent) {
            projectionResultCode = resultCode
            projectionData = Intent(data)
        }

        fun clearProjectionData() {
            projectionResultCode = null
            projectionData = null
        }
    }
}
