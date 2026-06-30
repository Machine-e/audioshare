import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'platform/audio_capture_bridge.dart';

void main() {
  runApp(const AudioShareApp());
}

enum AppSide { android, windows }

enum LinkStatus { idle, pairing, streaming, stopped, error }

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
  });

  final int latencyMs;
  final double packetLossPercent;
  final int bitrateKbps;
  final int jitterMs;
}

class AudioShareController extends ChangeNotifier {
  AudioShareController({AudioCaptureBridge? captureBridge})
    : _captureBridge = captureBridge ?? AudioCaptureBridge();

  final AudioCaptureBridge _captureBridge;

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
  String outputDevice = '默认输出设备';
  bool capturePermissionGranted = false;
  bool foregroundServiceEnabled = true;
  String lastMessage = '等待启动';

  Timer? _statsTimer;
  int _tick = 0;

  bool get isWindowsMode => side == AppSide.windows;
  bool get isAndroidMode => side == AppSide.android;
  bool get canStartWindows => isWindowsMode && status != LinkStatus.streaming;
  bool get canStartAndroid =>
      isAndroidMode &&
      capturePermissionGranted &&
      host.trim().isNotEmpty &&
      status != LinkStatus.streaming;

  void setSide(AppSide next) {
    if (side == next) return;
    _stopStats();
    side = next;
    status = LinkStatus.idle;
    stats = const StreamStats(
      latencyMs: 0,
      packetLossPercent: 0,
      bitrateKbps: 0,
      jitterMs: 0,
    );
    lastMessage = next == AppSide.windows ? 'Windows 接收端就绪' : 'Android 推流端就绪';
    notifyListeners();
  }

  void updateHost(String value) {
    host = value.trim();
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

  Future<void> requestCapturePermission() async {
    status = LinkStatus.pairing;
    lastMessage = '等待系统音频捕获授权';
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    capturePermissionGranted = true;
    status = LinkStatus.idle;
    lastMessage = '系统播放音频捕获已授权';
    notifyListeners();
  }

  Future<void> startWindowsServer() async {
    status = LinkStatus.pairing;
    lastMessage = '监听 $host:$port，等待 Android 输入配对码';
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 450));
    status = LinkStatus.streaming;
    lastMessage = '正在接收 Android 系统音频';
    _startStats();
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
    lastMessage = '正在连接 Windows $host:$port';
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 450));
    await _captureBridge.startForegroundService();
    status = LinkStatus.streaming;
    lastMessage = '正在后台推送系统播放音频';
    _startStats();
    notifyListeners();
  }

  void stop() {
    _stopStats();
    unawaited(_captureBridge.stopForegroundService());
    status = LinkStatus.stopped;
    stats = const StreamStats(
      latencyMs: 0,
      packetLossPercent: 0,
      bitrateKbps: 0,
      jitterMs: 0,
    );
    lastMessage = '已停止';
    notifyListeners();
  }

  void _startStats() {
    _statsTimer?.cancel();
    _tick = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _tick += 1;
      stats = StreamStats(
        latencyMs: 42 + (_tick % 9),
        packetLossPercent: (_tick % 4) * 0.1,
        bitrateKbps: audioConfig.bitrateKbps,
        jitterMs: 4 + (_tick % 5),
      );
      notifyListeners();
    });
  }

  void _stopStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  @override
  void dispose() {
    _stopStats();
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
                            Expanded(child: _PrimaryPanel(controller: controller)),
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
                      : ListView(
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
              const SizedBox(height: 20),
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
          onPressed: controller.canStartAndroid ? controller.startAndroidStream : null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('开始推流'),
        ),
        OutlinedButton.icon(
          onPressed: controller.status == LinkStatus.streaming ? controller.stop : null,
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
          onPressed: controller.canStartWindows ? controller.startWindowsServer : null,
          icon: const Icon(Icons.sensors),
          label: const Text('开始监听'),
        ),
        OutlinedButton.icon(
          onPressed: controller.status == LinkStatus.streaming ? controller.stop : null,
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
              DropdownMenuEntry(value: NetworkProvider.tailscale, label: 'Tailscale'),
              DropdownMenuEntry(value: NetworkProvider.easyTier, label: 'EasyTier'),
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
            readOnly: true,
            decoration: InputDecoration(
              labelText: '配对码',
              prefixIcon: const Icon(Icons.password),
              suffixIcon: IconButton(
                tooltip: '刷新配对码',
                icon: const Icon(Icons.refresh),
                onPressed: () {},
              ),
            ),
            controller: TextEditingController(text: controller.pairingCode),
          ),
          const SizedBox(height: 12),
          DropdownMenu<String>(
            label: const Text('Windows 输出设备'),
            initialSelection: controller.outputDevice,
            onSelected: (value) {
              if (value != null) controller.setOutputDevice(value);
            },
            dropdownMenuEntries: const [
              DropdownMenuEntry(value: '默认输出设备', label: '默认输出设备'),
              DropdownMenuEntry(value: '扬声器', label: '扬声器'),
              DropdownMenuEntry(value: '耳机', label: '耳机'),
              DropdownMenuEntry(value: '虚拟输出设备', label: '虚拟输出设备'),
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
            _StatCard(label: '丢包', value: '${stats.packetLossPercent.toStringAsFixed(1)}%'),
            _StatCard(label: '码率', value: '${stats.bitrateKbps} kbps'),
            _StatCard(label: '抖动', value: '${stats.jitterMs} ms'),
          ],
        );
      },
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
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
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
      LinkStatus.streaming => ('传输中', Icons.graphic_eq, Colors.green),
      LinkStatus.stopped => ('已停止', Icons.stop_circle_outlined, Colors.grey),
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
  const _PanelCard({required this.child, this.padding = const EdgeInsets.all(20)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: padding, child: child),
    );
  }
}
