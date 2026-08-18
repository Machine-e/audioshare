import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'platform/external_route_bridge.dart';

void main() => runApp(const AudioShareApp());

enum SinkPhase {
  stopped,
  starting,
  waitingForRoute,
  opened,
  stopping,
  disconnected,
  error,
}

class AudioShareController extends ChangeNotifier {
  AudioShareController({required this.bridge, required this.isWindows});
  final ExternalRouteBridge bridge;
  final bool isWindows;
  List<BluetoothDeviceInfo> devices = const [];
  String? selectedDeviceId;
  SinkPhase phase = SinkPhase.stopped;
  bool loadingDevices = false;
  String detail = '';
  String deviceError = '';
  int _sessionEpoch = 0;
  int _deviceEpoch = 0;
  bool _disposed = false;

  Future<void> refreshDevices() async {
    if (!isWindows || loadingDevices || _disposed) return;
    final epoch = ++_deviceEpoch;
    loadingDevices = true;
    _notify();
    try {
      final found = await bridge.listBluetoothDevices();
      if (_disposed || epoch != _deviceEpoch) return;
      devices = found;
      deviceError = '';
      selectedDeviceId = found.any((d) => d.id == selectedDeviceId)
          ? selectedDeviceId
          : (found.length == 1 ? found.first.id : null);
    } catch (e) {
      if (!_disposed && epoch == _deviceEpoch) {
        deviceError = '刷新失败：$e';
      }
    } finally {
      if (!_disposed && epoch == _deviceEpoch) {
        loadingDevices = false;
        _notify();
      }
    }
  }

  void selectDevice(String? id) {
    selectedDeviceId = id;
    _notify();
  }

  Future<void> start() async {
    final id = selectedDeviceId;
    if (!isWindows || id == null || _disposed || loadingDevices) return;
    _deviceEpoch++;
    loadingDevices = false;
    final epoch = ++_sessionEpoch;
    phase = SinkPhase.starting;
    detail = '';
    _notify();
    try {
      final status = await bridge.startBluetoothSink(deviceId: id);
      if (_disposed || epoch != _sessionEpoch) return;
      _apply(status);
      if (!_terminal(phase)) unawaited(_watch(epoch));
    } catch (e) {
      if (!_disposed && epoch == _sessionEpoch) {
        phase = SinkPhase.error;
        detail = '启动失败：$e';
        _notify();
      }
    }
  }

  Future<void> _watch(int epoch) async {
    while (!_disposed && epoch == _sessionEpoch && !_terminal(phase)) {
      try {
        final status = await bridge.waitBluetoothSinkStatusChange();
        if (_disposed || epoch != _sessionEpoch) return;
        _apply(status);
      } catch (e) {
        if (!_disposed && epoch == _sessionEpoch) {
          phase = SinkPhase.error;
          detail = '$e';
          _notify();
        }
        return;
      }
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    final epoch = ++_sessionEpoch;
    _deviceEpoch++;
    loadingDevices = false;
    phase = SinkPhase.stopping;
    _notify();
    try {
      final status = await bridge.stopBluetoothSink();
      if (!_disposed && epoch == _sessionEpoch) _apply(status);
    } catch (e) {
      if (!_disposed && epoch == _sessionEpoch) {
        phase = SinkPhase.error;
        detail = '停止失败：$e';
        _notify();
      }
    }
  }

  void _apply(BluetoothSinkStatus status) {
    phase = switch (status.state) {
      NativeSinkState.stopped => SinkPhase.stopped,
      NativeSinkState.waitingForRoute => SinkPhase.waitingForRoute,
      NativeSinkState.opened => SinkPhase.opened,
      NativeSinkState.disconnected => SinkPhase.disconnected,
      NativeSinkState.error => SinkPhase.error,
    };
    detail = status.message;
    if (_terminal(phase)) {
      _sessionEpoch++;
      _deviceEpoch++;
      loadingDevices = false;
    }
    _notify();
  }

  bool _terminal(SinkPhase value) => {
    SinkPhase.stopped,
    SinkPhase.disconnected,
    SinkPhase.error,
  }.contains(value);
  Future<void> openBluetoothSettings() => bridge.openBluetoothSettings();
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionEpoch++;
    _deviceEpoch++;
    super.dispose();
  }
}

class AudioShareApp extends StatelessWidget {
  const AudioShareApp({super.key, this.bridge, this.platform});
  final ExternalRouteBridge? bridge;
  final TargetPlatform? platform;
  @override
  Widget build(BuildContext context) {
    final current = platform ?? defaultTargetPlatform;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AudioShare',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff315bd6)),
        fontFamily: 'Geist Sans',
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff8ca7ff),
          brightness: Brightness.dark,
        ),
        fontFamily: 'Geist Sans',
        useMaterial3: true,
      ),
      home: HomeScreen(
        bridge: bridge ?? ExternalRouteBridge(),
        isWindows: current == TargetPlatform.windows,
        isAndroid: current == TargetPlatform.android,
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AudioShare')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: widget.isWindows
                ? _WindowsContent(controller)
                : widget.isAndroid
                ? _AndroidContent(widget.bridge)
                : const Text('当前平台不支持。'),
          ),
        ),
      ),
    ),
  );
}

class _WindowsContent extends StatelessWidget {
  const _WindowsContent(this.controller);
  final AudioShareController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final active = {
        SinkPhase.starting,
        SinkPhase.waitingForRoute,
        SinkPhase.opened,
        SinkPhase.stopping,
      }.contains(controller.phase);
      final status = switch (controller.phase) {
        SinkPhase.stopped => ('尚未启动接收', '选择已配对的手机，然后启动接收。'),
        SinkPhase.starting => ('正在启动接收', '正在启用 Windows 蓝牙音频接收器。'),
        SinkPhase.waitingForRoute => ('等待手机选择此电脑', '在手机的媒体输出或播放设备中选择此电脑。'),
        SinkPhase.opened => ('手机媒体路由已连接', '手机已将媒体路由连接到此电脑。'),
        SinkPhase.stopping => ('正在停止', '正在关闭蓝牙音频接收器。'),
        SinkPhase.disconnected => ('连接已断开', '请确认配对和媒体音频设置，然后重新启动。'),
        SinkPhase.error => (
          '出现错误',
          controller.detail.isEmpty ? '请重试。' : controller.detail,
        ),
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '让手机音频在这台电脑上播放',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 20),
          Text('选择手机', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (controller.loadingDevices) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
          ] else if (controller.devices.isEmpty) ...[
            const Text('未找到已配对手机。请先配对，并在手机上为此电脑启用“媒体音频”。'),
            const SizedBox(height: 8),
          ] else
            DropdownButtonFormField<String>(
              key: const Key('device-dropdown'),
              initialValue: controller.selectedDeviceId,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '已配对的手机',
              ),
              items: controller.devices
                  .map(
                    (d) => DropdownMenuItem(
                      value: d.id,
                      child: Text(d.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: active ? null : controller.selectDevice,
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: controller.loadingDevices
                    ? null
                    : controller.refreshDevices,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新设备'),
              ),
              OutlinedButton.icon(
                key: const Key('windows-settings'),
                onPressed: controller.openBluetoothSettings,
                icon: const Icon(Icons.settings_bluetooth),
                label: const Text('打开 Windows 蓝牙设置'),
              ),
            ],
          ),
          if (controller.deviceError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(controller.deviceError),
          ],
          const SizedBox(height: 20),
          Semantics(
            key: const Key('status-semantics'),
            liveRegion: true,
            excludeSemantics: true,
            label: '${status.$1}。${status.$2}',
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status.$1,
                      key: const Key('status-title'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(status.$2),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (active)
            OutlinedButton.icon(
              key: const Key('stop-button'),
              onPressed: controller.phase == SinkPhase.stopping
                  ? null
                  : controller.stop,
              icon: const Icon(Icons.stop),
              label: Text(
                controller.phase == SinkPhase.starting ? '取消启动' : '停止接收',
              ),
            )
          else
            FilledButton.icon(
              key: const Key('start-button'),
              onPressed:
                  controller.selectedDeviceId == null ||
                      controller.loadingDevices
                  ? null
                  : controller.start,
              icon: const Icon(Icons.play_arrow),
              label: const Text('启动接收'),
            ),
        ],
      );
    },
  );
}

class _AndroidContent extends StatelessWidget {
  const _AndroidContent(this.bridge);
  final ExternalRouteBridge bridge;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('将电脑设为手机媒体输出', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 16),
      const Text('AudioShare 不采集或传输音频，连接与输出选择均由系统蓝牙完成。'),
      const SizedBox(height: 16),
      const Text('1. 与 Windows 电脑完成蓝牙配对。'),
      const SizedBox(height: 10),
      const Text('2. 为这台电脑启用“媒体音频”。'),
      const SizedBox(height: 10),
      const Text('3. 播放时在媒体输出中选择这台电脑。'),
      const SizedBox(height: 20),
      FilledButton.icon(
        key: const Key('android-settings'),
        onPressed: bridge.openBluetoothSettings,
        icon: const Icon(Icons.settings_bluetooth),
        label: const Text('打开系统蓝牙设置'),
      ),
    ],
  );
}
