import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'android_screen.dart';
import 'app_style.dart';
import 'platform/android_update_bridge.dart';
import 'platform/companion_bridge.dart';
import 'platform/external_route_bridge.dart';

void main() => runApp(const AudioShareApp(enableUpdateChecks: true));

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
  String? preferredDeviceId;
  String? get selectedDeviceId =>
      devices.any((d) => d.id == preferredDeviceId) ? preferredDeviceId : null;
  SinkPhase phase = SinkPhase.stopped;
  bool loadingDevices = false;
  int deviceRefreshRequests = 0;
  int deviceRefreshResults = 0;
  String detail = '';
  String deviceError = '';
  int _sessionEpoch = 0;
  int _deviceEpoch = 0;
  bool _disposed = false;
  bool _preferenceLoaded = false;
  bool _userSelected = false;
  Future<void> _preferenceWrites = Future.value();

  Future<void> initialize() async {
    if (!isWindows || _preferenceLoaded || _disposed) return;
    _preferenceLoaded = true;
    final preference = () async {
      try {
        final cached = await bridge.readPreferredDevice();
        if (!_disposed && !_userSelected) {
          preferredDeviceId = cached;
          _notify();
        }
      } catch (_) {
        // Preferences are a convenience and must never block Bluetooth controls.
      }
    }();
    await Future.wait([preference, refreshDevices()]);
  }

  Future<void> refreshDevices() async {
    if (!isWindows || loadingDevices || _disposed) return;
    final epoch = ++_deviceEpoch;
    deviceRefreshRequests++;
    loadingDevices = true;
    _notify();
    try {
      final found = await bridge.listBluetoothDevices();
      if (_disposed || epoch != _deviceEpoch) return;
      devices = found;
      deviceRefreshResults++;
      deviceError = '';
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
    if (_disposed || id == null || _active) return;
    _userSelected = true;
    preferredDeviceId = id;
    _notify();
    _preferenceWrites = _preferenceWrites.then((_) async {
      try {
        await bridge.writePreferredDevice(id);
      } catch (_) {
        // A failed cache write must not undo an explicit user selection.
      }
    });
  }

  Future<void> start() async {
    final id = selectedDeviceId;
    if (!isWindows || id == null || _disposed || loadingDevices || _active) {
      return;
    }
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
  bool get _active => {
    SinkPhase.starting,
    SinkPhase.waitingForRoute,
    SinkPhase.opened,
    SinkPhase.stopping,
  }.contains(phase);
  Future<void> openBluetoothSettings() async {
    if (_disposed) return;
    try {
      await bridge.openBluetoothSettings();
    } catch (e) {
      if (!_disposed) {
        deviceError = '无法打开蓝牙设置：$e';
        _notify();
      }
    }
  }

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

class AudioShareApp extends StatefulWidget {
  const AudioShareApp({
    super.key,
    this.bridge,
    this.companionBridge,
    this.platform,
    this.enableUpdateChecks = false,
  });
  final ExternalRouteBridge? bridge;
  final CompanionBridge? companionBridge;
  final TargetPlatform? platform;
  final bool enableUpdateChecks;
  @override
  State<AudioShareApp> createState() => _AudioShareAppState();
}

class _AudioShareAppState extends State<AudioShareApp> {
  ThemeMode mode = ThemeMode.system;
  late final ExternalRouteBridge bridge =
      widget.bridge ?? ExternalRouteBridge();
  late final CompanionBridge companion =
      widget.companionBridge ?? CompanionBridge();
  bool selectedTheme = false;
  Future<void> themeWrites = Future.value();

  @override
  void initState() {
    super.initState();
    unawaited(_loadTheme());
  }

  Future<void> _loadTheme() async {
    try {
      final saved = await bridge.readThemeMode();
      if (mounted && !selectedTheme) {
        setState(
          () => mode = ThemeMode.values.firstWhere(
            (value) => value.name == saved,
            orElse: () => ThemeMode.system,
          ),
        );
      }
    } catch (_) {
      /* Use the system appearance if preferences are unavailable. */
    }
  }

  void _setTheme(ThemeMode value) {
    selectedTheme = true;
    setState(() => mode = value);
    themeWrites = themeWrites.then((_) async {
      try {
        await bridge.writeThemeMode(value.name);
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.platform ?? defaultTargetPlatform;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AudioShare',
      themeMode: mode,
      themeAnimationDuration:
          WidgetsBinding
              .instance
              .platformDispatcher
              .accessibilityFeatures
              .disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 280),
      theme: audioShareTheme(Brightness.light),
      darkTheme: audioShareTheme(Brightness.dark),
      home: HomeScreen(
        bridge: bridge,
        companionBridge: companion,
        isWindows: current == TargetPlatform.windows,
        isAndroid: current == TargetPlatform.android,
        enableUpdateChecks: widget.enableUpdateChecks,
        themeMode: mode,
        onThemeChanged: _setTheme,
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.bridge,
    required this.companionBridge,
    required this.isWindows,
    required this.isAndroid,
    required this.enableUpdateChecks,
    required this.themeMode,
    required this.onThemeChanged,
  });
  final ExternalRouteBridge bridge;
  final CompanionBridge companionBridge;
  final bool isWindows;
  final bool isAndroid;
  final bool enableUpdateChecks;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
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
    if (widget.isWindows) unawaited(controller.initialize());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AmbientBackground(
    child: Scaffold(
      appBar: AppBar(
        title: const Text('AudioShare'),
        actions: [
          PopupMenuButton<ThemeMode>(
            key: const Key('theme-menu'),
            tooltip: '外观',
            initialValue: widget.themeMode,
            onSelected: widget.onThemeChanged,
            icon: Icon(
              Theme.of(context).brightness == Brightness.dark
                  ? Icons.dark_mode_outlined
                  : Icons.light_mode_outlined,
            ),
            itemBuilder: (_) => [
              for (final option in [
                (ThemeMode.light, '亮色'),
                (ThemeMode.dark, '暗色'),
                (ThemeMode.system, '跟随系统'),
              ])
                CheckedPopupMenuItem(
                  value: option.$1,
                  checked: widget.themeMode == option.$1,
                  child: Text(option.$2),
                ),
            ],
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: widget.isWindows ? 1040 : 560,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              child: widget.isWindows
                  ? _WindowsContent(controller)
                  : widget.isAndroid
                  ? AndroidScreen(
                      routeBridge: widget.bridge,
                      companionBridge: widget.companionBridge,
                      updateBridge: widget.enableUpdateChecks
                          ? AndroidUpdateBridge()
                          : null,
                    )
                  : const Text('当前平台不支持。'),
            ),
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
            '让声音，在这里继续。',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '从手机，到电脑。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final hero = Semantics(
                key: const Key('status-semantics'),
                liveRegion: true,
                excludeSemantics: true,
                label: '${status.$1}。${status.$2}',
                child: GlassSurface(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      children: [
                        AudioHalo(
                          active: controller.phase == SinkPhase.opened,
                          icon: controller.phase == SinkPhase.opened
                              ? Icons.bluetooth_connected
                              : Icons.headphones_rounded,
                        ),
                        const SizedBox(height: 20),
                        AnimatedSwitcher(
                          duration: motionDuration(context),
                          layoutBuilder: (current, previous) =>
                              current ?? const SizedBox.shrink(),
                          child: Text(
                            status.$1,
                            key: ValueKey(status.$1),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(status.$2, textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              );
              final controls = GlassSurface(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '选择设备',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      if (controller.loadingDevices) ...[
                        const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                      ] else if (controller.devices.isEmpty) ...[
                        const Text('未找到已配对手机。请先配对，并在手机上为此电脑启用“媒体音频”。'),
                        const SizedBox(height: 8),
                      ] else
                        DropdownButton<String>(
                          key: const Key('device-dropdown'),
                          value: controller.selectedDeviceId,
                          isExpanded: true,
                          hint: const Text('选择已配对的手机'),
                          items: controller.devices
                              .map(
                                (d) => DropdownMenuItem(
                                  value: d.id,
                                  child: Text(
                                    d.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: active ? null : controller.selectDevice,
                        ),
                      if (controller.preferredDeviceId != null &&
                          controller.selectedDeviceId == null &&
                          controller.devices.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        const Text('上次选择的设备当前不可用，请重新选择。'),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: controller.loadingDevices
                                ? null
                                : controller.refreshDevices,
                            icon: AnimatedRotation(
                              turns: controller.deviceRefreshRequests
                                  .toDouble(),
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 650),
                              curve: Curves.easeInOutCubic,
                              child: const Icon(Icons.refresh),
                            ),
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
                      if (!controller.loadingDevices &&
                          controller.deviceError.isEmpty &&
                          controller.deviceRefreshResults > 0)
                        Text(
                          '已刷新设备列表 · ${controller.devices.length} 台 · 第 ${controller.deviceRefreshResults} 次',
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
                            controller.phase == SinkPhase.starting
                                ? '取消启动'
                                : '停止接收',
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
                          label: Text(
                            controller.phase == SinkPhase.disconnected ||
                                    controller.phase == SinkPhase.error
                                ? '手动重试'
                                : '启动接收',
                          ),
                        ),
                    ],
                  ),
                ),
              );
              if (constraints.maxWidth >= 640 &&
                  MediaQuery.textScalerOf(context).scale(14) < 20) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: hero),
                    const SizedBox(width: 20),
                    Expanded(child: controls),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [hero, const SizedBox(height: 20), controls],
              );
            },
          ),
          const SizedBox(height: 16),
          _StatusServiceCard(controller.bridge),
          const SizedBox(height: 16),
          const ExpansionTile(
            title: Text('使用帮助'),
            children: [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text('关闭窗口时可按提示保留托盘接收。遇到问题请检查 Windows 蓝牙设置和配对状态。'),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class _StatusServiceCard extends StatefulWidget {
  const _StatusServiceCard(this.bridge);
  final ExternalRouteBridge bridge;
  @override
  State<_StatusServiceCard> createState() => _StatusServiceCardState();
}

class _StatusServiceCardState extends State<_StatusServiceCard> {
  bool? available;
  String message = '';
  bool loading = false;
  int requests = 0;
  int completed = 0;
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (loading) return;
    setState(() {
      loading = true;
      requests++;
    });
    try {
      final info = await widget.bridge.getStatusServiceInfo();
      if (mounted) {
        setState(() {
          available = info.available;
          message = info.message;
          completed++;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          available = false;
          message = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => GlassSurface(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Icon(available == true ? Icons.sync : Icons.sync_problem),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('手机状态同步', style: Theme.of(context).textTheme.titleMedium),
                Text(
                  loading
                      ? '正在检查…'
                      : available == true
                      ? '可用${message.isEmpty ? '' : '：$message'}'
                      : '不可用${message.isEmpty ? '' : '：$message'}',
                ),
                if (!loading && completed > 0)
                  Text(
                    '已读取最新服务状态 · 第 $completed 次（不重新配对或重启音频）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          IconButton(
            key: const Key('refresh-status-service'),
            tooltip: '重新读取状态服务',
            onPressed: loading ? null : refresh,
            icon: AnimatedRotation(
              key: const Key('status-refresh-rotation'),
              turns: requests.toDouble(),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 650),
              curve: Curves.easeInOutCubic,
              child: const Icon(Icons.refresh),
            ),
          ),
        ],
      ),
    ),
  );
}
