import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show
        InternetAddress,
        Platform,
        RawDatagramSocket,
        RawSocketEvent,
        ServerSocket,
        Socket;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform/audio_capture_bridge.dart';
import 'platform/windows_audio_player.dart';
import 'protocol/audio_packet.dart';

void main() {
  runApp(const AudioShareApp());
}

enum AppSide { android, windows }

enum LinkStatus {
  idle,
  pairing,
  connected,
  paired,
  capturing,
  streaming,
  stopped,
  disconnected,
  error,
}

enum LinkProbeStatus { idle, checking, listening, reachable, failed }

enum NetworkProvider { easyTier, tailscale, manual }

class AudioConfig {
  const AudioConfig({
    required this.bitrateKbps,
    required this.bufferMs,
    this.sampleRate = 48000,
    this.frameMs = 20,
  });

  final int bitrateKbps;
  final int bufferMs;
  final int sampleRate;
  final int frameMs;
}

class StreamStats {
  const StreamStats({
    required this.latencyMs,
    required this.packetLossPercent,
    required this.bitrateKbps,
    required this.jitterMs,
    this.pcmFramesCaptured = 0,
    this.opusFramesEncoded = 0,
    this.udpPacketsSent = 0,
    this.udpPacketsReceived = 0,
    this.playedFrames = 0,
    this.sendErrors = 0,
    this.readErrors = 0,
    this.zeroFrames = 0,
    this.underruns = 0,
  });

  final int latencyMs;
  final double packetLossPercent;
  final int bitrateKbps;
  final int jitterMs;
  final int pcmFramesCaptured;
  final int opusFramesEncoded;
  final int udpPacketsSent;
  final int udpPacketsReceived;
  final int playedFrames;
  final int sendErrors;
  final int readErrors;
  final int zeroFrames;
  final int underruns;
}

class RuntimeStatus {
  const RuntimeStatus({
    this.controlConnected = false,
    this.mediaProjectionAuthorized = false,
    this.audioRecordCapturing = false,
    this.opusEncoding = false,
    this.udpPacketsSent = false,
    this.udpPacketsReceived = false,
    this.windowsPlaybackActive = false,
  });

  final bool controlConnected;
  final bool mediaProjectionAuthorized;
  final bool audioRecordCapturing;
  final bool opusEncoding;
  final bool udpPacketsSent;
  final bool udpPacketsReceived;
  final bool windowsPlaybackActive;

  RuntimeStatus copyWith({
    bool? controlConnected,
    bool? mediaProjectionAuthorized,
    bool? audioRecordCapturing,
    bool? opusEncoding,
    bool? udpPacketsSent,
    bool? udpPacketsReceived,
    bool? windowsPlaybackActive,
  }) {
    return RuntimeStatus(
      controlConnected: controlConnected ?? this.controlConnected,
      mediaProjectionAuthorized:
          mediaProjectionAuthorized ?? this.mediaProjectionAuthorized,
      audioRecordCapturing: audioRecordCapturing ?? this.audioRecordCapturing,
      opusEncoding: opusEncoding ?? this.opusEncoding,
      udpPacketsSent: udpPacketsSent ?? this.udpPacketsSent,
      udpPacketsReceived: udpPacketsReceived ?? this.udpPacketsReceived,
      windowsPlaybackActive:
          windowsPlaybackActive ?? this.windowsPlaybackActive,
    );
  }
}

class _SessionInfo {
  const _SessionInfo({required this.sessionId, required this.authKey});

  final int sessionId;
  final String authKey;
}

class AudioShareController extends ChangeNotifier {
  AudioShareController({AudioCaptureBridge? captureBridge})
    : _captureBridge = captureBridge ?? AudioCaptureBridge();

  final AudioCaptureBridge _captureBridge;
  final WindowsAudioPlayer _windowsAudioPlayer = WindowsAudioPlayer();

  AppSide side = Platform.isWindows ? AppSide.windows : AppSide.android;
  LinkStatus status = LinkStatus.idle;
  NetworkProvider networkProvider = NetworkProvider.tailscale;
  AudioConfig audioConfig = const AudioConfig(bitrateKbps: 96, bufferMs: 80);
  StreamStats stats = const StreamStats(
    latencyMs: 0,
    packetLossPercent: 0,
    bitrateKbps: 0,
    jitterMs: 0,
  );

  String host = '100.64.0.2';
  int port = 47820;
  String pairingCode = '482-917';
  String outputDevice = 'default';
  List<WindowsOutputDevice> outputDevices =
      WindowsAudioPlayer.fallbackOutputDevices;
  bool capturePermissionGranted = false;
  bool foregroundServiceEnabled = true;
  String lastMessage = '等待启动';
  LinkProbeStatus probeStatus = LinkProbeStatus.idle;
  String probeMessage = '尚未测试连接';
  RuntimeStatus runtimeStatus = const RuntimeStatus();

  Timer? _connectionProbeTimer;
  ServerSocket? _windowsProbeServer;
  StreamSubscription<Socket>? _windowsProbeSubscription;
  RawDatagramSocket? _windowsUdpSocket;
  StreamSubscription<RawSocketEvent>? _windowsUdpSubscription;
  StreamSubscription<CaptureRuntimeStats>? _androidStatsSubscription;
  _SessionInfo? _activeSession;
  int _windowsReceivedPackets = 0;
  int _lastWindowsSequence = -1;
  int _missedHeartbeats = 0;
  bool _probeInFlight = false;

  bool get isWindowsMode => side == AppSide.windows;
  bool get isAndroidMode => side == AppSide.android;
  bool get isActive =>
      status == LinkStatus.pairing ||
      status == LinkStatus.paired ||
      status == LinkStatus.capturing ||
      status == LinkStatus.streaming;
  bool get canStartWindows => isWindowsMode && !isActive;
  bool get canStartAndroid =>
      isAndroidMode &&
      capturePermissionGranted &&
      host.trim().isNotEmpty &&
      !isActive;
  bool get canStop => isActive;
  bool get canTestConnection =>
      isAndroidMode && host.trim().isNotEmpty && !_probeInFlight;

  void setSide(AppSide next) {
    if (side == next) return;
    _resetRuntimeStats();
    _stopAndroidStats();
    _stopConnectionProbeLoop();
    unawaited(_stopWindowsProbeServer());
    side = next;
    status = LinkStatus.idle;
    _activeSession = null;
    _windowsReceivedPackets = 0;
    _lastWindowsSequence = -1;
    _missedHeartbeats = 0;
    probeStatus = LinkProbeStatus.idle;
    probeMessage = '尚未测试连接';
    lastMessage = next == AppSide.windows ? 'Windows 接收端就绪' : 'Android 推流端就绪';
    if (next == AppSide.windows) {
      unawaited(loadOutputDevices());
    }
    notifyListeners();
  }

  void updateHost(String value) {
    host = value.trim();
    if (isAndroidMode && status != LinkStatus.streaming) {
      probeStatus = LinkProbeStatus.idle;
      probeMessage = '主机已更新，尚未测试连接';
    }
    notifyListeners();
  }

  void updatePort(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed <= 0 || parsed > 65535) {
      lastMessage = '端口必须在 1-65535 之间';
      status = LinkStatus.error;
    } else {
      port = parsed;
      if (status == LinkStatus.error) status = LinkStatus.idle;
      if (status != LinkStatus.streaming) {
        probeStatus = LinkProbeStatus.idle;
        probeMessage = '端口已更新，尚未测试连接';
      }
      lastMessage = '端口已更新';
    }
    notifyListeners();
  }

  void updateBitrate(double value) {
    audioConfig = AudioConfig(
      bitrateKbps: value.round(),
      bufferMs: audioConfig.bufferMs,
      sampleRate: audioConfig.sampleRate,
      frameMs: audioConfig.frameMs,
    );
    notifyListeners();
  }

  void updateBuffer(double value) {
    audioConfig = AudioConfig(
      bitrateKbps: audioConfig.bitrateKbps,
      bufferMs: value.round(),
      sampleRate: audioConfig.sampleRate,
      frameMs: audioConfig.frameMs,
    );
    notifyListeners();
  }

  void setNetworkProvider(NetworkProvider provider) {
    networkProvider = provider;
    notifyListeners();
  }

  void setOutputDevice(String value) {
    outputDevice = value;
    notifyListeners();
  }

  Future<void> loadOutputDevices() async {
    final devices = _windowsAudioPlayer.listOutputDevices();
    outputDevices = devices.isEmpty
        ? WindowsAudioPlayer.fallbackOutputDevices
        : devices;
    if (!outputDevices.any((device) => device.id == outputDevice)) {
      outputDevice = outputDevices
          .firstWhere(
            (device) => device.isDefault,
            orElse: () => outputDevices.first,
          )
          .id;
    }
    notifyListeners();
  }

  void updatePairingCode(String value) {
    pairingCode = value.trim();
    notifyListeners();
  }

  void refreshPairingCode() {
    final random = Random.secure();
    final digits = List.generate(6, (_) => random.nextInt(10)).join();
    pairingCode = '${digits.substring(0, 3)}-${digits.substring(3)}';
    notifyListeners();
  }

  Future<void> requestCapturePermission() async {
    status = LinkStatus.pairing;
    lastMessage = '正在打开系统音频捕获授权弹窗';
    notifyListeners();
    try {
      capturePermissionGranted = await _captureBridge
          .requestCapturePermission();
      status = capturePermissionGranted ? LinkStatus.idle : LinkStatus.error;
      lastMessage = capturePermissionGranted ? '系统播放音频捕获已授权' : '系统音频捕获授权未完成';
    } on PlatformException catch (error) {
      capturePermissionGranted = false;
      status = LinkStatus.error;
      lastMessage = error.message ?? '系统音频捕获授权失败';
    } catch (error) {
      capturePermissionGranted = false;
      status = LinkStatus.error;
      lastMessage = '系统音频捕获授权失败：$error';
    }
    notifyListeners();
  }

  Future<void> startWindowsServer() async {
    status = LinkStatus.pairing;
    lastMessage = '正在打开 Windows 监听端口 $port';
    notifyListeners();
    final listening = await _startWindowsProbeServer();
    if (!listening) return;
    status = LinkStatus.pairing;
    lastMessage = 'Windows 已监听 TCP/UDP $port，等待 Android 配对';
    notifyListeners();
  }

  Future<void> startAndroidStream() async {
    if (!capturePermissionGranted) {
      status = LinkStatus.error;
      lastMessage = '请先授予系统播放音频捕获权限';
      notifyListeners();
      return;
    }
    status = LinkStatus.pairing;
    lastMessage = '正在与 Windows $host:$port 建立 v1 控制会话';
    notifyListeners();
    final session = await _startControlSession();
    if (session == null) return;
    try {
      _activeSession = session;
      _startAndroidStats();
      await _captureBridge.startForegroundService(
        CaptureStartConfig(
          host: host,
          controlPort: port,
          udpPort: port,
          pairingCode: pairingCode,
          sessionId: session.sessionId,
          audioAuthKey: session.authKey,
          bitrateKbps: audioConfig.bitrateKbps,
          sampleRate: audioConfig.sampleRate,
          frameMs: audioConfig.frameMs,
          bufferMs: audioConfig.bufferMs,
        ),
      );
      status = LinkStatus.capturing;
      runtimeStatus = runtimeStatus.copyWith(
        controlConnected: true,
        mediaProjectionAuthorized: true,
      );
      lastMessage = '控制会话已配对，正在等待 AudioRecord 捕获音频';
      _startConnectionProbeLoop();
    } on PlatformException catch (error) {
      status = LinkStatus.error;
      lastMessage = error.message ?? 'Android 前台推流服务启动失败';
    } catch (error) {
      status = LinkStatus.error;
      lastMessage = 'Android 前台推流服务启动失败：$error';
    }
    notifyListeners();
  }

  void stop() {
    _resetRuntimeStats();
    _stopAndroidStats();
    _stopConnectionProbeLoop();
    unawaited(_sendStopStream());
    unawaited(_stopWindowsProbeServer());
    unawaited(_captureBridge.stopForegroundService());
    _windowsAudioPlayer.stop();
    status = LinkStatus.stopped;
    probeStatus = LinkProbeStatus.idle;
    probeMessage = '连接测试已停止';
    _activeSession = null;
    _windowsReceivedPackets = 0;
    _lastWindowsSequence = -1;
    _missedHeartbeats = 0;
    lastMessage = '已停止';
    notifyListeners();
  }

  Future<bool> testConnection() async {
    if (isWindowsMode) {
      return _startWindowsProbeServer();
    }
    return _probeWindowsHost(failStreamOnError: true);
  }

  Future<bool> _startWindowsProbeServer() async {
    if (_windowsProbeServer != null) {
      probeStatus = LinkProbeStatus.listening;
      probeMessage = 'Windows 已监听 0.0.0.0:$port，等待连接测试或 v1 配对';
      notifyListeners();
      return true;
    }

    probeStatus = LinkProbeStatus.checking;
    probeMessage = '正在检查本机端口 $port 是否可监听';
    notifyListeners();

    try {
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      final udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
      );
      _windowsProbeServer = server;
      _windowsUdpSocket = udpSocket;
      _windowsProbeSubscription = server.listen(
        _handleWindowsProbe,
        onError: (Object error) {
          probeStatus = LinkProbeStatus.failed;
          probeMessage = 'Windows 监听异常：$error';
          status = LinkStatus.error;
          lastMessage = probeMessage;
          notifyListeners();
        },
      );
      _windowsUdpSubscription = udpSocket.listen(_handleWindowsUdpEvent);
      probeStatus = LinkProbeStatus.listening;
      probeMessage = 'Windows 已监听 0.0.0.0:$port TCP/UDP，等待 Android 连接';
      notifyListeners();
      return true;
    } catch (error) {
      probeStatus = LinkProbeStatus.failed;
      probeMessage = '无法监听端口 $port：$error';
      status = LinkStatus.error;
      lastMessage = probeMessage;
      notifyListeners();
      return false;
    }
  }

  void _handleWindowsProbe(Socket client) {
    unawaited(() async {
      final lines = StreamIterator(
        client
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
      try {
        final line = await _readControlLine(lines);
        if (line.startsWith('AUDIOSHARE_PROBE')) {
          client.add(utf8.encode('AUDIOSHARE_OK\n'));
          await client.flush();
          probeStatus = LinkProbeStatus.reachable;
          if (!isActive) {
            status = LinkStatus.connected;
            probeMessage = '已收到 Android 连接测试，链路可达';
            lastMessage = '连接测试通过，等待开始音频会话';
          } else {
            probeMessage = 'Android 心跳正常，音频会话保持可达';
            lastMessage = 'Windows 正在接收音频，Android 心跳正常';
          }
        } else if (line.trim() == 'Hello protocol_version=1 role=android') {
          client.add(utf8.encode('Hello protocol_version=1 role=windows\n'));
          await client.flush();
          final pairLine = await _readControlLine(lines);
          final code = pairLine.startsWith('Pair code=')
              ? pairLine.substring('Pair code='.length).trim()
              : '';
          if (_normalizePairingCode(code) !=
              _normalizePairingCode(pairingCode)) {
            client.add(utf8.encode('PairRejected reason=bad_code\n'));
            await client.flush();
            status = LinkStatus.error;
            lastMessage = '配对码错误，Windows 已拒绝 Android 会话';
            probeStatus = LinkProbeStatus.failed;
            probeMessage = lastMessage;
            notifyListeners();
            return;
          }
          final sessionId =
              DateTime.now().microsecondsSinceEpoch & 0x7FFFFFFFFFFFFFFF;
          final authKey = _deriveAudioAuthKey(pairingCode, sessionId);
          _activeSession = _SessionInfo(sessionId: sessionId, authKey: authKey);
          client.add(
            utf8.encode(
              'PairAccepted session_id=$sessionId token_hint=${authKey.substring(0, 8)} audio_key=$authKey\n',
            ),
          );
          await client.flush();
          final startLine = await _readControlLine(lines);
          if (startLine.trim() != 'StartStream') {
            throw StateError('未收到 StartStream');
          }
          status = LinkStatus.paired;
          runtimeStatus = runtimeStatus.copyWith(controlConnected: true);
          probeStatus = LinkProbeStatus.reachable;
          probeMessage = 'v1 控制会话已配对，等待 UDP 音频包';
          lastMessage = 'Android 已通过配对，Windows 等待音频数据';
        } else if (line.trim() == 'StopStream') {
          _resetWindowsReceiverSession();
          status = LinkStatus.disconnected;
          probeStatus = LinkProbeStatus.listening;
          probeMessage = '收到 StopStream，Windows 保持监听';
          lastMessage = 'Android 已停止推流';
        } else {
          throw StateError('未知控制消息：$line');
        }
        if (status == LinkStatus.connected) {
          status = LinkStatus.connected;
        }
        notifyListeners();
      } catch (error) {
        probeStatus = LinkProbeStatus.failed;
        probeMessage = '收到连接但探测失败：$error';
        notifyListeners();
      } finally {
        await lines.cancel();
        await client.close();
      }
    }());
  }

  void _handleWindowsUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _windowsUdpSocket?.receive();
    if (datagram == null) return;
    final session = _activeSession;
    if (session == null) return;
    try {
      final packet = AudioPacketCodec.decode(datagram.data, session.authKey);
      if (packet.sessionId != session.sessionId) {
        throw StateError('session_id 不匹配');
      }
      final isLatePacket =
          _lastWindowsSequence >= 0 && packet.sequence <= _lastWindowsSequence;
      final expected = _lastWindowsSequence + 1;
      final missed =
          !isLatePacket &&
              _lastWindowsSequence >= 0 &&
              packet.sequence > expected
          ? packet.sequence - expected
          : 0;
      if (!isLatePacket) {
        _windowsReceivedPackets += 1;
        _lastWindowsSequence = packet.sequence;
      }
      if (!_windowsAudioPlayer.start(
        sampleRate: audioConfig.sampleRate,
        channels: 2,
        frameMs: audioConfig.frameMs,
        bitrateKbps: audioConfig.bitrateKbps,
        bufferMs: audioConfig.bufferMs,
        outputDevice: outputDevice,
      )) {
        throw StateError(_windowsAudioPlayer.lastError ?? 'Windows 原生播放器不可用');
      }
      final playedFrames = _windowsAudioPlayer.pushPacket(
        sequence: packet.sequence,
        timestampMs: packet.timestampMs,
        payload: Uint8List.fromList(packet.payload),
      );
      if (playedFrames < 0) {
        throw StateError(_windowsAudioPlayer.lastError ?? 'Windows 播放失败');
      }
      runtimeStatus = runtimeStatus.copyWith(
        controlConnected: true,
        udpPacketsReceived: true,
        windowsPlaybackActive: true,
      );
      status = LinkStatus.streaming;
      stats = StreamStats(
        latencyMs: DateTime.now().millisecondsSinceEpoch - packet.timestampMs,
        packetLossPercent: _windowsReceivedPackets == 0
            ? 0
            : (missed / (_windowsReceivedPackets + missed)) * 100,
        bitrateKbps: audioConfig.bitrateKbps,
        jitterMs: audioConfig.bufferMs,
        udpPacketsReceived: _windowsReceivedPackets,
        playedFrames: stats.playedFrames + playedFrames,
        underruns: stats.underruns + missed,
      );
      lastMessage = 'Windows 已收到 ${stats.udpPacketsReceived} 个认证 UDP 音频包';
      notifyListeners();
    } catch (error) {
      status = LinkStatus.error;
      lastMessage = 'UDP 音频包认证或解析失败：$error';
      notifyListeners();
    }
  }

  Future<bool> _probeWindowsHost({required bool failStreamOnError}) async {
    if (_probeInFlight) return probeStatus == LinkProbeStatus.reachable;
    _probeInFlight = true;
    probeStatus = LinkProbeStatus.checking;
    probeMessage = '正在连接 $host:$port';
    notifyListeners();

    Socket? socket;
    try {
      socket = await Socket.connect(
        host.trim(),
        port,
        timeout: const Duration(seconds: 3),
      );
      socket.add(utf8.encode('AUDIOSHARE_PROBE $pairingCode\n'));
      await socket.flush();
      final response = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 2), onTimeout: () => '');
      final ok = response.trim() == 'AUDIOSHARE_OK';
      if (!ok) {
        throw StateError('目标端口未返回 AudioShare 探测响应');
      }
      probeStatus = LinkProbeStatus.reachable;
      probeMessage = '连接测试通过：$host:$port 可达';
      _missedHeartbeats = 0;
      if (status == LinkStatus.error) status = LinkStatus.idle;
      notifyListeners();
      return true;
    } catch (error) {
      probeStatus = LinkProbeStatus.failed;
      probeMessage = '连接测试失败：$error';
      if (failStreamOnError) {
        status = LinkStatus.error;
        lastMessage = '无法连接 Windows $host:$port';
      } else if (status == LinkStatus.streaming ||
          status == LinkStatus.capturing ||
          status == LinkStatus.paired) {
        lastMessage = 'Windows 心跳探测失败，请检查虚拟网络或接收端';
      }
      notifyListeners();
      return false;
    } finally {
      socket?.destroy();
      _probeInFlight = false;
    }
  }

  void _startConnectionProbeLoop() {
    _stopConnectionProbeLoop();
    if (!isAndroidMode) return;
    _connectionProbeTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (status == LinkStatus.streaming ||
          status == LinkStatus.capturing ||
          status == LinkStatus.paired) {
        unawaited(_checkHeartbeat());
      }
    });
  }

  Future<void> _checkHeartbeat() async {
    final reachable = await _probeWindowsHost(failStreamOnError: false);
    if (reachable) {
      _missedHeartbeats = 0;
      return;
    }

    _missedHeartbeats += 1;
    if (_missedHeartbeats >= 3) {
      await _handleDisconnected('Windows 接收端心跳超时，已停止 Android 捕获和发送');
      return;
    }

    lastMessage = 'Windows 心跳丢失 $_missedHeartbeats/3，将在超时后停止捕获';
    notifyListeners();
  }

  Future<void> _handleDisconnected(String message) async {
    _stopAndroidStats();
    _stopConnectionProbeLoop();
    await _captureBridge.stopForegroundService();
    _activeSession = null;
    _missedHeartbeats = 0;
    runtimeStatus = runtimeStatus.copyWith(
      controlConnected: false,
      mediaProjectionAuthorized: false,
      audioRecordCapturing: false,
      opusEncoding: false,
      udpPacketsSent: false,
    );
    status = LinkStatus.disconnected;
    lastMessage = message;
    notifyListeners();
  }

  void _stopConnectionProbeLoop() {
    _connectionProbeTimer?.cancel();
    _connectionProbeTimer = null;
  }

  Future<void> _stopWindowsProbeServer() async {
    await _windowsProbeSubscription?.cancel();
    _windowsProbeSubscription = null;
    await _windowsProbeServer?.close();
    _windowsProbeServer = null;
    await _windowsUdpSubscription?.cancel();
    _windowsUdpSubscription = null;
    _windowsUdpSocket?.close();
    _windowsUdpSocket = null;
  }

  void _resetWindowsReceiverSession() {
    _windowsAudioPlayer.stop();
    _activeSession = null;
    _windowsReceivedPackets = 0;
    _lastWindowsSequence = -1;
    runtimeStatus = const RuntimeStatus();
  }

  Future<_SessionInfo?> _startControlSession() async {
    Socket? socket;
    StreamIterator<String>? lines;
    try {
      socket = await Socket.connect(
        host.trim(),
        port,
        timeout: const Duration(seconds: 3),
      );
      lines = StreamIterator(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
      socket.add(utf8.encode('Hello protocol_version=1 role=android\n'));
      await socket.flush();
      final hello = await _readControlLine(lines);
      if (hello.trim() != 'Hello protocol_version=1 role=windows') {
        throw StateError('Windows 未返回兼容的 Hello');
      }
      socket.add(utf8.encode('Pair code=$pairingCode\n'));
      await socket.flush();
      final pairResponse = await _readControlLine(lines);
      if (pairResponse.startsWith('PairRejected')) {
        throw StateError('Windows 拒绝配对，请检查配对码');
      }
      if (!pairResponse.startsWith('PairAccepted ')) {
        throw StateError('Windows 未返回 PairAccepted');
      }
      final fields = _parseControlFields(pairResponse);
      final sessionId = int.parse(fields['session_id'] ?? '0');
      final authKey =
          fields['audio_key'] ?? _deriveAudioAuthKey(pairingCode, sessionId);
      _missedHeartbeats = 0;
      socket.add(utf8.encode('StartStream\n'));
      await socket.flush();
      status = LinkStatus.paired;
      probeStatus = LinkProbeStatus.reachable;
      probeMessage = 'v1 控制会话已配对：session $sessionId';
      runtimeStatus = runtimeStatus.copyWith(controlConnected: true);
      notifyListeners();
      return _SessionInfo(sessionId: sessionId, authKey: authKey);
    } catch (error) {
      status = LinkStatus.error;
      probeStatus = LinkProbeStatus.failed;
      probeMessage = 'v1 控制会话失败：$error';
      lastMessage = '无法建立音频会话，连接测试不再等同于推流成功';
      notifyListeners();
      return null;
    } finally {
      await lines?.cancel();
      await socket?.close();
    }
  }

  Future<String> _readControlLine(StreamIterator<String> lines) async {
    final hasLine = await lines.moveNext().timeout(
      const Duration(seconds: 2),
      onTimeout: () => false,
    );
    return hasLine ? lines.current : '';
  }

  Future<void> _sendStopStream() async {
    if (!isAndroidMode || _activeSession == null) return;
    try {
      final socket = await Socket.connect(
        host.trim(),
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.add(utf8.encode('StopStream\n'));
      await socket.flush();
      await socket.close();
    } catch (_) {
      // Best-effort control-plane stop; local cleanup has already run.
    }
  }

  void _startAndroidStats() {
    _stopAndroidStats();
    _androidStatsSubscription = _captureBridge.runtimeStats().listen(
      (event) {
        runtimeStatus = runtimeStatus.copyWith(
          mediaProjectionAuthorized: event.mediaProjectionAuthorized,
          audioRecordCapturing: event.audioRecordCapturing,
          opusEncoding: event.opusEncoding,
          udpPacketsSent: event.udpPacketsSent > 0,
        );
        stats = StreamStats(
          latencyMs: stats.latencyMs,
          packetLossPercent: event.sendErrors > 0 ? 100 : 0,
          bitrateKbps: event.udpPacketsSent > 0 ? audioConfig.bitrateKbps : 0,
          jitterMs: audioConfig.bufferMs,
          pcmFramesCaptured: event.pcmFramesCaptured,
          opusFramesEncoded: event.opusFramesEncoded,
          udpPacketsSent: event.udpPacketsSent,
          sendErrors: event.sendErrors,
          readErrors: event.readErrors,
          zeroFrames: event.zeroFrames,
          underruns: event.underruns,
        );
        if (event.udpPacketsSent > 0) {
          status = LinkStatus.streaming;
          lastMessage = 'Android 正在发送真实捕获数据包：${event.udpPacketsSent}';
        } else if (event.audioRecordCapturing) {
          status = LinkStatus.capturing;
          lastMessage = event.lastMessage.isEmpty
              ? 'AudioRecord 捕获中'
              : event.lastMessage;
        } else if (event.lastMessage.isNotEmpty) {
          lastMessage = event.lastMessage;
        }
        notifyListeners();
      },
      onError: (Object error) {
        status = LinkStatus.error;
        lastMessage = 'Android 捕获状态通道异常：$error';
        notifyListeners();
      },
    );
  }

  void _stopAndroidStats() {
    unawaited(_androidStatsSubscription?.cancel());
    _androidStatsSubscription = null;
  }

  void _resetRuntimeStats() {
    stats = const StreamStats(
      latencyMs: 0,
      packetLossPercent: 0,
      bitrateKbps: 0,
      jitterMs: 0,
    );
    runtimeStatus = const RuntimeStatus();
  }

  String _deriveAudioAuthKey(String code, int sessionId) {
    final normalized = _normalizePairingCode(code);
    return 'audioshare-v1:$normalized:$sessionId';
  }

  String _normalizePairingCode(String value) {
    return value.split('').where((char) => '0123456789'.contains(char)).join();
  }

  Map<String, String> _parseControlFields(String line) {
    final fields = <String, String>{};
    for (final part in line.split(' ').skip(1)) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      fields[part.substring(0, index)] = part.substring(index + 1);
    }
    return fields;
  }

  @override
  void dispose() {
    _resetRuntimeStats();
    _stopAndroidStats();
    _stopConnectionProbeLoop();
    unawaited(_stopWindowsProbeServer());
    _windowsAudioPlayer.stop();
    super.dispose();
  }
}

class AudioShareApp extends StatelessWidget {
  const AudioShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AudioShare',
      themeMode: ThemeMode.system,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: const HomeScreen(),
    );
  }
}

ThemeData _buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2563EB),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Geist Sans',
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: const AppBarTheme(centerTitle: false),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      filled: true,
      fillColor: scheme.surfaceContainerLow,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final AudioShareController controller;
  late final TextEditingController hostController;
  late final TextEditingController portController;

  @override
  void initState() {
    super.initState();
    controller = AudioShareController();
    hostController = TextEditingController(text: controller.host);
    portController = TextEditingController(text: controller.port.toString());
    if (controller.isWindowsMode) {
      unawaited(controller.loadOutputDevices());
    }
  }

  @override
  void dispose() {
    controller.dispose();
    hostController.dispose();
    portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final wide = MediaQuery.sizeOf(context).width >= 860;
        return Scaffold(
          appBar: AppBar(
            title: const Text('AudioShare'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: _StatusPill(status: controller.status),
              ),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _PrimaryPanel(controller: controller),
                            ),
                            const SizedBox(width: 16),
                            SizedBox(
                              width: 360,
                              child: _SettingsPanel(
                                controller: controller,
                                hostController: hostController,
                                portController: portController,
                              ),
                            ),
                          ],
                        )
                      : SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _PrimaryPanel(controller: controller),
                              const SizedBox(height: 16),
                              _SettingsPanel(
                                controller: controller,
                                hostController: hostController,
                                portController: portController,
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PrimaryPanel extends StatelessWidget {
  const _PrimaryPanel({required this.controller});

  final AudioShareController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<AppSide>(
          segments: const [
            ButtonSegment(
              value: AppSide.android,
              icon: Icon(Icons.phone_android),
              label: Text('Android 推流'),
            ),
            ButtonSegment(
              value: AppSide.windows,
              icon: Icon(Icons.desktop_windows_outlined),
              label: Text('Windows 接收'),
            ),
          ],
          selected: {controller.side},
          onSelectionChanged: (value) => controller.setSide(value.first),
        ),
        const SizedBox(height: 16),
        _PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                controller.isAndroidMode ? '系统音频推流' : 'Windows 音频接收',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                controller.isAndroidMode
                    ? '采集 Android 12+ 允许捕获的媒体播放音频，通过虚拟网发送到 Windows。'
                    : '在虚拟网 IP 上监听 Android 推流，解码后播放到选定输出设备。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              if (controller.isAndroidMode)
                _AndroidActions(controller: controller)
              else
                _WindowsActions(controller: controller),
              const SizedBox(height: 16),
              _ConnectionStatusCard(
                status: controller.probeStatus,
                message: controller.probeMessage,
                isWindowsMode: controller.isWindowsMode,
              ),
              const SizedBox(height: 16),
              _RuntimeStatusCard(
                status: controller.runtimeStatus,
                stats: controller.stats,
              ),
              if (controller.isAndroidMode) ...[
                const SizedBox(height: 16),
                const _CompatibilityCard(),
              ],
              const SizedBox(height: 16),
              _MessageStrip(message: controller.lastMessage),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _StatsGrid(stats: controller.stats),
      ],
    );
  }
}

class _AndroidActions extends StatelessWidget {
  const _AndroidActions({required this.controller});

  final AudioShareController controller;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        FilledButton.icon(
          onPressed: controller.capturePermissionGranted
              ? null
              : controller.requestCapturePermission,
          icon: const Icon(Icons.audio_file_outlined),
          label: Text(controller.capturePermissionGranted ? '已授权捕获' : '授权系统音频'),
        ),
        FilledButton.tonalIcon(
          onPressed: controller.canTestConnection
              ? controller.testConnection
              : null,
          icon: const Icon(Icons.network_check),
          label: const Text('测试连接'),
        ),
        FilledButton.icon(
          onPressed: controller.canStartAndroid
              ? controller.startAndroidStream
              : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('开始推流'),
        ),
        OutlinedButton.icon(
          onPressed: controller.canStop ? controller.stop : null,
          icon: const Icon(Icons.stop),
          label: const Text('停止'),
        ),
      ],
    );
  }
}

class _WindowsActions extends StatelessWidget {
  const _WindowsActions({required this.controller});

  final AudioShareController controller;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        FilledButton.icon(
          onPressed: controller.canStartWindows
              ? controller.startWindowsServer
              : null,
          icon: const Icon(Icons.sensors),
          label: const Text('开始监听'),
        ),
        OutlinedButton.icon(
          onPressed: controller.canStop ? controller.stop : null,
          icon: const Icon(Icons.stop),
          label: const Text('停止'),
        ),
      ],
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.controller,
    required this.hostController,
    required this.portController,
  });

  final AudioShareController controller;
  final TextEditingController hostController;
  final TextEditingController portController;

  @override
  Widget build(BuildContext context) {
    return _PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('连接设置', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          DropdownMenu<NetworkProvider>(
            label: const Text('外部组网'),
            initialSelection: controller.networkProvider,
            onSelected: (value) {
              if (value != null) controller.setNetworkProvider(value);
            },
            dropdownMenuEntries: const [
              DropdownMenuEntry(
                value: NetworkProvider.tailscale,
                label: 'Tailscale',
              ),
              DropdownMenuEntry(
                value: NetworkProvider.easyTier,
                label: 'EasyTier',
              ),
              DropdownMenuEntry(value: NetworkProvider.manual, label: '手动虚拟网'),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: hostController,
            decoration: const InputDecoration(
              labelText: 'Windows 虚拟网 IP',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
            onChanged: controller.updateHost,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: portController,
            decoration: const InputDecoration(
              labelText: '监听端口',
              prefixIcon: Icon(Icons.tag),
            ),
            keyboardType: TextInputType.number,
            onChanged: controller.updatePort,
          ),
          const SizedBox(height: 12),
          TextField(
            readOnly: controller.isWindowsMode,
            decoration: InputDecoration(
              labelText: '配对码',
              prefixIcon: const Icon(Icons.password),
              suffixIcon: controller.isWindowsMode
                  ? IconButton(
                      tooltip: '刷新配对码',
                      icon: const Icon(Icons.refresh),
                      onPressed: controller.refreshPairingCode,
                    )
                  : null,
            ),
            controller: TextEditingController(text: controller.pairingCode),
            onChanged: controller.isAndroidMode
                ? controller.updatePairingCode
                : null,
          ),
          const SizedBox(height: 12),
          DropdownMenu<String>(
            label: const Text('Windows 输出设备'),
            initialSelection: controller.outputDevice,
            onSelected: (value) {
              if (value != null) controller.setOutputDevice(value);
            },
            dropdownMenuEntries: [
              for (final device in controller.outputDevices)
                DropdownMenuEntry(
                  value: device.id,
                  label: device.isDefault ? '${device.name}（默认）' : device.name,
                ),
            ],
          ),
          const SizedBox(height: 20),
          _SliderSetting(
            label: 'Opus 码率',
            value: controller.audioConfig.bitrateKbps.toDouble(),
            min: 48,
            max: 192,
            divisions: 6,
            suffix: '${controller.audioConfig.bitrateKbps} kbps',
            onChanged: controller.updateBitrate,
          ),
          _SliderSetting(
            label: '缓冲',
            value: controller.audioConfig.bufferMs.toDouble(),
            min: 40,
            max: 180,
            divisions: 7,
            suffix: '${controller.audioConfig.bufferMs} ms',
            onChanged: controller.updateBuffer,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Android 前台服务'),
            subtitle: const Text('后台和息屏时保持推流'),
            value: controller.foregroundServiceEnabled,
            onChanged: null,
          ),
        ],
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats});

  final StreamStats stats;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 640 ? 4 : 2;
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 2.1,
          children: [
            _StatCard(label: '延迟', value: '${stats.latencyMs} ms'),
            _StatCard(
              label: '丢包',
              value: '${stats.packetLossPercent.toStringAsFixed(1)}%',
            ),
            _StatCard(label: '码率', value: '${stats.bitrateKbps} kbps'),
            _StatCard(label: '抖动', value: '${stats.jitterMs} ms'),
            _StatCard(label: 'PCM 帧', value: '${stats.pcmFramesCaptured}'),
            _StatCard(label: 'Opus 帧', value: '${stats.opusFramesEncoded}'),
            _StatCard(label: 'UDP 发包', value: '${stats.udpPacketsSent}'),
            _StatCard(label: 'UDP 收包', value: '${stats.udpPacketsReceived}'),
          ],
        );
      },
    );
  }
}

class _RuntimeStatusCard extends StatelessWidget {
  const _RuntimeStatusCard({required this.status, required this.stats});

  final RuntimeStatus status;
  final StreamStats stats;

  @override
  Widget build(BuildContext context) {
    return _PanelCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('运行状态', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          _StatusRow(label: 'TCP 控制已连接', enabled: status.controlConnected),
          _StatusRow(
            label: 'MediaProjection 已授权',
            enabled: status.mediaProjectionAuthorized,
          ),
          _StatusRow(
            label: 'AudioRecord 正在捕获',
            enabled: status.audioRecordCapturing,
          ),
          _StatusRow(label: 'Opus 正在编码', enabled: status.opusEncoding),
          _StatusRow(label: 'UDP 已发送', enabled: status.udpPacketsSent),
          _StatusRow(label: 'UDP 已接收', enabled: status.udpPacketsReceived),
          _StatusRow(
            label: 'Windows 播放活跃',
            enabled: status.windowsPlaybackActive,
          ),
          if (stats.zeroFrames > 0 ||
              stats.readErrors > 0 ||
              stats.sendErrors > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '诊断：静音帧 ${stats.zeroFrames}，读取错误 ${stats.readErrors}，发送错误 ${stats.sendErrors}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.enabled});

  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Colors.green : Colors.grey;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            enabled ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class _CompatibilityCard extends StatelessWidget {
  const _CompatibilityCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.speaker_notes_outlined,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'AudioShare 只能捕获允许系统播放捕获的应用；第三方应用是否继续本机外放，取决于源应用、设备路由和系统音频焦点策略。',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionStatusCard extends StatelessWidget {
  const _ConnectionStatusCard({
    required this.status,
    required this.message,
    required this.isWindowsMode,
  });

  final LinkProbeStatus status;
  final String message;
  final bool isWindowsMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, icon, color, activeBar) = switch (status) {
      LinkProbeStatus.idle => (
        '未测试',
        Icons.radio_button_unchecked,
        Colors.grey,
        false,
      ),
      LinkProbeStatus.checking => ('检测中', Icons.sync, Colors.orange, true),
      LinkProbeStatus.listening => ('监听中', Icons.sensors, Colors.blue, true),
      LinkProbeStatus.reachable => (
        '已连通',
        Icons.check_circle,
        Colors.green,
        false,
      ),
      LinkProbeStatus.failed => ('不可达', Icons.error_outline, Colors.red, false),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (status == LinkProbeStatus.checking)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: color,
                    ),
                  )
                else
                  Icon(icon, size: 20, color: color),
                const SizedBox(width: 10),
                Text(
                  isWindowsMode ? 'Windows 连接状态' : 'Android 连接状态',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(color: color),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: activeBar
                    ? null
                    : (status == LinkProbeStatus.reachable ? 1 : 0),
                minHeight: 6,
                color: color,
                backgroundColor: color.withValues(alpha: 0.15),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _PanelCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final LinkStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = switch (status) {
      LinkStatus.idle => ('空闲', Icons.radio_button_unchecked, Colors.grey),
      LinkStatus.pairing => ('配对中', Icons.sync, Colors.orange),
      LinkStatus.connected => ('已连接', Icons.link, Colors.blue),
      LinkStatus.paired => ('已配对', Icons.verified_user_outlined, Colors.blue),
      LinkStatus.capturing => (
        '捕获中',
        Icons.mic_external_on_outlined,
        Colors.teal,
      ),
      LinkStatus.streaming => ('传输中', Icons.graphic_eq, Colors.green),
      LinkStatus.stopped => ('已停止', Icons.stop_circle_outlined, Colors.grey),
      LinkStatus.disconnected => ('已断开', Icons.link_off, Colors.orange),
      LinkStatus.error => ('错误', Icons.error_outline, Colors.red),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        color: color.withValues(alpha: 0.08),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label),
          ],
        ),
      ),
    );
  }
}

class _MessageStrip extends StatelessWidget {
  const _MessageStrip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _SliderSetting extends StatelessWidget {
  const _SliderSetting({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.suffix,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(suffix, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: suffix,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _PanelCard extends StatelessWidget {
  const _PanelCard({
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: padding, child: child),
    );
  }
}
