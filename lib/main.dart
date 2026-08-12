import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'platform/external_route_bridge.dart';

void main() => runApp(const AudioShareApp());

class AudioShareController extends ChangeNotifier {
  AudioShareController({required this.bridge, required this.isWindows});

  final ExternalRouteBridge bridge;
  final bool isWindows;
  List<BluetoothDeviceInfo> devices = const [];
  String? selectedDeviceId;
  bool loading = false;
  bool starting = false;
  bool connected = false;
  String message = '';
  Timer? _statusTimer;
  bool _polling = false;
  bool _disposed = false;
  int _operation = 0;

  Future<void> refreshDevices() async {
    if (!isWindows || loading || _disposed) return;
    final operation = ++_operation;
    loading = true;
    _notify();
    try {
      final result = await bridge.listBluetoothDevices();
      if (_disposed || operation != _operation) return;
      final previous = selectedDeviceId;
      devices = result;
      selectedDeviceId = result.any((device) => device.id == previous)
          ? previous
          : (result.length == 1 ? result.first.id : null);
      message = '';
    } catch (error) {
      if (!_disposed && operation == _operation) {
        message = '刷新失败：$error';
      }
    } finally {
      if (!_disposed && operation == _operation) {
        loading = false;
        _notify();
      }
    }
  }

  void selectDevice(String? id) {
    if (_disposed || selectedDeviceId == id) return;
    selectedDeviceId = id;
    _notify();
  }

  Future<void> start() async {
    final id = selectedDeviceId;
    if (!isWindows || id == null || loading || _disposed) return;
    final operation = ++_operation;
    loading = true;
    starting = true;
    _notify();
    try {
      final status = await bridge.startBluetoothSink(deviceId: id);
      if (_disposed || operation != _operation) return;
      connected = status.isConnected;
      message = connected
          ? '接收已启动。请在手机的媒体或音频输出选择器中选择此电脑。'
          : status.message;
      if (connected) _beginPolling();
    } catch (error) {
      if (!_disposed && operation == _operation) {
        connected = false;
        message = '启动失败：$error';
      }
    } finally {
      if (!_disposed && operation == _operation) {
        loading = false;
        starting = false;
        _notify();
      }
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    final operation = ++_operation;
    _statusTimer?.cancel();
    _statusTimer = null;
    loading = false;
    starting = false;
    connected = false;
    message = '正在停止蓝牙接收…';
    _notify();
    try {
      final status = await bridge.stopBluetoothSink();
      if (_disposed || operation != _operation) return;
      message = status.message.isEmpty ? '已停止蓝牙接收。' : status.message;
    } catch (error) {
      if (_disposed || operation != _operation) return;
      message = '停止失败：$error';
    }
    _notify();
  }

  Future<void> openBluetoothSettings() => bridge.openBluetoothSettings();

  void _beginPolling() {
    if (_disposed) return;
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_disposed || !connected || _polling) return;
    _polling = true;
    try {
      final status = await bridge.getBluetoothSinkStatus();
      if (_disposed) return;
      if (!status.isConnected) {
        _statusTimer?.cancel();
        _statusTimer = null;
        connected = false;
        message =
            '蓝牙连接已断开。请确认手机仍已配对，在 Windows 重新启动接收，'
            '再从手机的媒体或音频输出选择器中选择此电脑。';
        _notify();
      }
    } catch (_) {
      // A transient status query should not tear down a working native sink.
    } finally {
      _polling = false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _operation++;
    _statusTimer?.cancel();
    super.dispose();
  }
}

class AudioShareApp extends StatelessWidget {
  const AudioShareApp({super.key, this.bridge, this.platform});

  final ExternalRouteBridge? bridge;
  final TargetPlatform? platform;

  @override
  Widget build(BuildContext context) {
    final currentPlatform = platform ?? defaultTargetPlatform;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AudioShare',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff315bd6)),
        useMaterial3: true,
        fontFamily: 'Geist Sans',
      ),
      home: HomeScreen(
        bridge: bridge ?? ExternalRouteBridge(),
        isWindows: currentPlatform == TargetPlatform.windows,
        isAndroid: currentPlatform == TargetPlatform.android,
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.bridge,
    required this.isWindows,
    required this.isAndroid,
  });

  final ExternalRouteBridge bridge;
  final bool isWindows;
  final bool isAndroid;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final AudioShareController controller;

  @override
  void initState() {
    super.initState();
    controller = AudioShareController(
      bridge: widget.bridge,
      isWindows: widget.isWindows,
    );
    if (widget.isWindows) unawaited(controller.refreshDevices());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AudioShare · 蓝牙音频接收')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: widget.isWindows
                  ? _WindowsContent(controller: controller)
                  : widget.isAndroid
                  ? _AndroidContent(bridge: widget.bridge)
                  : const _UnsupportedContent(),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowsContent extends StatelessWidget {
  const _WindowsContent({required this.controller});
  final AudioShareController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Bluetooth A2DP Sink',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text('从支持经典蓝牙 A2DP 的 Android 手机接收媒体音频。无需局域网、采集或额外传输。'),
          const SizedBox(height: 24),
          if (controller.devices.isEmpty && !controller.loading)
            const Text('未找到可用手机。请先完成系统蓝牙配对，并确认手机已为此电脑启用“媒体音频”，再刷新。')
          else
            DropdownButtonFormField<String>(
              key: const Key('device-dropdown'),
              initialValue: controller.selectedDeviceId,
              decoration: const InputDecoration(
                labelText: '已配对的 A2DP 手机',
                border: OutlineInputBorder(),
              ),
              items: controller.devices
                  .map(
                    (device) => DropdownMenuItem(
                      value: device.id,
                      child: Text(device.name),
                    ),
                  )
                  .toList(),
              onChanged: controller.connected ? null : controller.selectDevice,
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: controller.loading
                    ? null
                    : controller.refreshDevices,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新设备'),
              ),
              OutlinedButton.icon(
                onPressed: controller.openBluetoothSettings,
                icon: const Icon(Icons.settings_bluetooth),
                label: const Text('打开 Windows 蓝牙设置'),
              ),
              if (controller.connected || controller.starting)
                FilledButton.icon(
                  key: const Key('stop-button'),
                  onPressed: controller.stop,
                  icon: const Icon(Icons.stop),
                  label: Text(controller.starting ? '取消启动' : '停止接收'),
                )
              else
                FilledButton.icon(
                  key: const Key('start-button'),
                  onPressed:
                      controller.selectedDeviceId == null || controller.loading
                      ? null
                      : controller.start,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('启动接收'),
                ),
            ],
          ),
          if (controller.loading) ...[
            const SizedBox(height: 20),
            const LinearProgressIndicator(),
          ],
          if (controller.message.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(controller.message, key: const Key('status-message')),
          ],
          if (controller.connected) ...[
            const SizedBox(height: 12),
            const Text('已连接。请在手机的媒体输出、音频输出或播放设备中选择此电脑并播放。'),
          ],
        ],
      ),
    );
  }
}

class _AndroidContent extends StatelessWidget {
  const _AndroidContent({required this.bridge});
  final ExternalRouteBridge bridge;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('将电脑选为手机音频输出', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 12),
      const Text(
        '本应用不采集或传输音频。请先与 Windows 电脑完成普通蓝牙配对，'
        '并为此电脑启用“媒体音频”。播放媒体时，在系统的媒体输出、音频输出或播放设备中选择此电脑。'
        '不同品牌的入口名称和位置可能不同。',
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: bridge.openBluetoothSettings,
        icon: const Icon(Icons.settings_bluetooth),
        label: const Text('打开系统蓝牙设置'),
      ),
    ],
  );
}

class _UnsupportedContent extends StatelessWidget {
  const _UnsupportedContent();
  @override
  Widget build(BuildContext context) =>
      const Text('当前平台不支持。AudioShare 仅支持 Windows 接收端和 Android 引导。');
}
