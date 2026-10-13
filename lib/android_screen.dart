import 'app_style.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform/companion_bridge.dart';
import 'platform/android_update_bridge.dart';
import 'platform/external_route_bridge.dart';

Duration _motionDuration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 220);

class AndroidScreen extends StatefulWidget {
  const AndroidScreen({
    super.key,
    required this.routeBridge,
    required this.companionBridge,
    this.updateBridge,
  });
  final ExternalRouteBridge routeBridge;
  final CompanionBridge companionBridge;
  final AndroidUpdateBridge? updateBridge;
  @override
  State<AndroidScreen> createState() => _AndroidScreenState();
}

class _AndroidScreenState extends State<AndroidScreen>
    with WidgetsBindingObserver {
  CompanionSnapshot snapshot = const CompanionSnapshot();
  String? error;
  String? info;
  AndroidUpdateInfo? updateInfo;
  String? updateError;
  bool updateChecking = false, updateInstalling = false;
  AndroidDownloadProgress? downloadProgress;
  bool busy = false, tone = false, toneStarted = false, statusRetrying = false;
  int statusRefreshes = 0;
  int _lastRevision = -1;
  String _deviceFilter = '全部';
  int _page = 0;
  bool _active = true;
  bool? heard;
  StreamSubscription<CompanionSnapshot>? subscription;
  Timer? discoveryTimer, toneTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    subscription = widget.companionBridge.snapshots.listen(
      _apply,
      onError: (Object e) {
        if (mounted) {
          setState(() {
            snapshot = snapshot.withoutReceiver();
            error = '电脑状态更新中断：$e';
          });
        }
      },
    );
    unawaited(_loadSnapshot());
    if (widget.updateBridge != null) unawaited(_checkForUpdate());
  }

  void _apply(CompanionSnapshot value) {
    if (mounted && _active && value.revision > _lastRevision) {
      _lastRevision = value.revision;
      setState(() {
        snapshot = value;
        if (statusRefreshes > 0) {
          if (value.controlState == CompanionControlState.connected &&
              value.receiverMode != null) {
            info = '已收到电脑接收状态';
          } else if (value.controlState == CompanionControlState.unavailable) {
            info = '电脑状态同步失败，蓝牙音频独立工作';
          }
        }
      });
    }
  }

  Future<void> _loadSnapshot() async {
    try {
      _apply(await widget.companionBridge.getSnapshot());
    } catch (e) {
      if (mounted) {
        setState(() {
          snapshot = snapshot.withoutReceiver();
          error = '无法读取电脑状态：$e';
        });
      }
    }
  }

  Future<void> _companion(Future<CompanionSnapshot> future) async {
    try {
      _apply(await future);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _retryStatus() async {
    if (statusRetrying) return;
    setState(() {
      statusRetrying = true;
      statusRefreshes++;
      info = '正在刷新电脑状态…';
      error = null;
    });
    try {
      _apply(await widget.companionBridge.retryStatus());
      if (mounted &&
          snapshot.controlState == CompanionControlState.connecting) {
        setState(() => info = '正在连接状态服务，等待电脑报告');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '刷新电脑状态失败：$e';
          info = null;
        });
      }
    } finally {
      if (mounted) setState(() => statusRetrying = false);
    }
  }

  Future<void> _toggleTone() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (tone) {
        toneTimer?.cancel();
        await widget.routeBridge.stopTestTone();
        if (mounted) setState(() => tone = false);
      } else {
        await widget.routeBridge.playTestTone();
        if (!mounted || !_active) {
          await widget.routeBridge.stopTestTone();
          return;
        }
        if (mounted && _active) {
          setState(() {
            tone = true;
            toneStarted = true;
            heard = null;
          });
        }
        toneTimer = Timer(const Duration(milliseconds: 2500), () {
          if (mounted && _active) setState(() => tone = false);
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _checkForUpdate() async {
    if (widget.updateBridge == null || updateChecking || updateInstalling) {
      return;
    }
    setState(() {
      updateChecking = true;
      updateError = null;
    });
    try {
      final result = await widget.updateBridge!.checkForUpdate();
      if (mounted) {
        setState(() {
          updateInfo = result;
          updateError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => updateError = e is PlatformException
              ? e.message ?? '检查更新失败，请稍后重试'
              : '检查更新失败，请稍后重试',
        );
      }
    } finally {
      if (mounted) setState(() => updateChecking = false);
    }
  }

  Future<void> _installUpdate() async {
    final update = updateInfo;
    if (update == null || !update.available || updateInstalling) return;
    setState(() {
      updateInstalling = true;
      downloadProgress = const AndroidDownloadProgress();
      updateError = null;
    });
    try {
      await widget.updateBridge!.downloadAndInstall(
        update.downloadUrl,
        onProgress: (progress) {
          if (mounted && updateInstalling) {
            setState(() => downloadProgress = progress);
          }
        },
      );
      if (mounted) {
        setState(() {
          updateInstalling = false;
          downloadProgress = null;
          info = '安装包已下载，请在系统安装器中确认更新。';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          updateInstalling = false;
          downloadProgress = null;
          updateError = e is PlatformException
              ? e.message ?? '安装更新失败，请稍后重试'
              : '安装更新失败，请稍后重试';
          info = null;
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _active = true;
      unawaited(_loadSnapshot());
    } else {
      _active = false;
      setState(() => snapshot = snapshot.withoutReceiver());
      toneTimer?.cancel();
      if (tone) {
        setState(() => tone = false);
        unawaited(widget.routeBridge.stopTestTone().catchError((_) {}));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    subscription?.cancel();
    discoveryTimer?.cancel();
    toneTimer?.cancel();
    if (tone) {
      unawaited(widget.routeBridge.stopTestTone().catchError((_) {}));
    }
    super.dispose();
  }

  (String, String, IconData) get _computerStatus {
    if (snapshot.controlState != CompanionControlState.connected) {
      return switch (snapshot.controlState) {
        CompanionControlState.connecting => (
          '正在同步电脑状态',
          '状态同步不影响蓝牙音频连接。',
          Icons.sync,
        ),
        CompanionControlState.unavailable => (
          '电脑状态暂不可用',
          '仅状态服务连接失败，不代表蓝牙音频已断开。',
          Icons.cloud_off,
        ),
        _ => ('电脑状态未知', '状态通道未建立，不代表蓝牙音频已断开。', Icons.laptop_outlined),
      };
    }
    if (snapshot.receiverTarget == ReceiverTarget.otherPhone) {
      if (snapshot.receiverMode == 'opened' ||
          snapshot.receiverMode == 'waitingForRoute') {
        return ('电脑已选择其他手机', '请在电脑端选择本手机。', Icons.phonelink_erase);
      }
      return ('电脑未选择本手机', '电脑接收已停止或出错。', Icons.phonelink_erase);
    }
    if (snapshot.receiverTarget == ReceiverTarget.unknown) {
      if (snapshot.receiverMode == 'stopped') {
        return ('电脑接收已停止', '请在电脑端选择本手机并开启接收。', Icons.laptop_outlined);
      }
      if (snapshot.receiverMode == 'opened') {
        return ('电脑媒体路由已打开', '电脑未能确认接收目标，暂不能确认是否为本手机。', Icons.help_outline);
      }
      if (snapshot.receiverMode == 'error' ||
          snapshot.receiverMode == 'disconnected') {
        return (
          '电脑报告接收${snapshot.receiverMode == 'error' ? '出错' : '断开'}',
          '接收目标未知，请查看电脑端；本机蓝牙状态如下。',
          Icons.info_outline,
        );
      }
      return ('无法确认接收目标', '电脑未报告正在接收哪部手机。', Icons.help_outline);
    }
    return switch (snapshot.receiverMode) {
      'waitingForRoute' => (
        '电脑已准备好',
        '接收已开启，仍需在手机选择媒体输出。',
        Icons.laptop_chromebook,
      ),
      'opened' => ('连接已打开', '电脑已确认本手机媒体路由。', Icons.laptop_chromebook),
      'starting' => ('电脑正在启动接收', '请稍候。', Icons.sync),
      'error' => ('电脑接收出错', '请查看电脑端错误后重试。', Icons.error_outline),
      'stopped' => ('电脑接收已停止', '请在电脑端开启接收。', Icons.stop_circle_outlined),
      'disconnected' => ('连接已断开', '电脑报告媒体连接已经断开。', Icons.link_off),
      _ => ('电脑尚未准备好', '请在电脑端开启接收。', Icons.laptop_outlined),
    };
  }

  @override
  Widget build(BuildContext context) {
    final status = _computerStatus,
        selected = snapshot.devices
            .where((d) => d.id == snapshot.selectedDeviceId)
            .firstOrNull;
    final shownDevices = snapshot.devices
        .where(
          (d) => switch (_deviceFilter) {
            '最近使用' => d.recent,
            '收藏' => d.favorite,
            _ => true,
          },
        )
        .toList();
    final openedForThisPhone =
        snapshot.controlState == CompanionControlState.connected &&
        snapshot.receiverMode == 'opened' &&
        snapshot.receiverTarget == ReceiverTarget.thisPhone;
    final localConnected =
        selected != null &&
        selected.a2dpStateKnown &&
        (selected.a2dpConnected || selected.a2dpPlaying);
    final mediaPlaying =
        selected?.a2dpStateKnown == true && selected?.a2dpPlaying == true;
    final primaryTitle = mediaPlaying
        ? '正在通过电脑播放'
        : localConnected || openedForThisPhone
        ? '蓝牙媒体已连接'
        : selected == null
        ? '请选择一台电脑'
        : selected.a2dpStateKnown && !selected.bonding
        ? '蓝牙媒体已断开'
        : '尚未确认蓝牙媒体连接';
    final mediaState = localConnected || openedForThisPhone
        ? ConnectionIndicatorState.connected
        : selected?.bonding == true
        ? ConnectionIndicatorState.pending
        : selected?.a2dpStateKnown == true
        ? ConnectionIndicatorState.disconnected
        : ConnectionIndicatorState.unknown;
    final receiverState =
        snapshot.controlState == CompanionControlState.connecting
        ? ConnectionIndicatorState.pending
        : snapshot.controlState != CompanionControlState.connected ||
              snapshot.receiverTarget != ReceiverTarget.thisPhone
        ? ConnectionIndicatorState.unknown
        : switch (snapshot.receiverMode) {
            'opened' => ConnectionIndicatorState.connected,
            'error' ||
            'disconnected' ||
            'stopped' => ConnectionIndicatorState.disconnected,
            'starting' || 'waitingForRoute' => ConnectionIndicatorState.pending,
            _ => ConnectionIndicatorState.unknown,
          };
    final accessPrompt = <Widget>[
      if (!snapshot.permission)
        GlassSurface(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Icon(Icons.bluetooth_searching, size: 54),
                const SizedBox(height: 8),
                const Text(
                  '读取附近电脑需要蓝牙权限，仅用于发现、配对和连接，不会采集音频。',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('request-access'),
                  onPressed: () =>
                      _companion(widget.companionBridge.requestAccess()),
                  child: const Text('读取附近设备'),
                ),
              ],
            ),
          ),
        )
      else if (!snapshot.bluetoothEnabled)
        GlassSurface(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Text('蓝牙已关闭，请先开启蓝牙。'),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('enable-bluetooth'),
                  onPressed: () =>
                      _companion(widget.companionBridge.requestAccess()),
                  child: const Text('开启蓝牙'),
                ),
              ],
            ),
          ),
        ),
    ];
    final devicePage = <Widget>[
      Row(
        children: [
          Expanded(
            child: Text(
              '我的电脑',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          IconButton(
            key: const Key('discover'),
            tooltip: snapshot.discovering ? '停止搜索' : '搜索新电脑',
            onPressed: !snapshot.permission || !snapshot.bluetoothEnabled
                ? () => _companion(widget.companionBridge.requestAccess())
                : () => _companion(
                    snapshot.discovering
                        ? widget.companionBridge.stopDiscovery()
                        : widget.companionBridge.startDiscovery(),
                  ),
            icon: Icon(
              snapshot.discovering ? Icons.stop_circle_outlined : Icons.add,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      ...accessPrompt,
      if (snapshot.permission && snapshot.bluetoothEnabled) ...[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final label in ['全部', '最近使用', '收藏'])
              ChoiceChip(
                label: Text(label),
                selected: _deviceFilter == label,
                onSelected: (_) => setState(() => _deviceFilter = label),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (snapshot.discovering) ...[
          const Text('正在搜索附近电脑，12 秒后自动停止'),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            key: const Key('scan-progress'),
            tween: Tween(begin: 0, end: 1),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(seconds: 12),
            builder: (context, elapsed, _) =>
                LinearProgressIndicator(value: elapsed),
          ),
          const SizedBox(height: 12),
        ],
        if (snapshot.devices.isEmpty)
          GlassSurface(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Text('没有找到电脑'),
                  const SizedBox(height: 8),
                  const Text('可搜索附近电脑 12 秒；配对确认将由系统显示。'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('discover-empty'),
                    onPressed: snapshot.discovering
                        ? null
                        : () {
                            _companion(widget.companionBridge.startDiscovery());
                            discoveryTimer?.cancel();
                            discoveryTimer = Timer(
                              const Duration(seconds: 12),
                              () => _companion(
                                widget.companionBridge.stopDiscovery(),
                              ),
                            );
                          },
                    icon: const Icon(Icons.search),
                    label: Text(snapshot.discovering ? '正在搜索…' : '搜索附近设备'),
                  ),
                ],
              ),
            ),
          )
        else if (shownDevices.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('这里还没有电脑，试试“全部”。'),
          )
        else
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var i = 0; i < shownDevices.length; i++)
                _DeviceCard(
                  key: ValueKey(shownDevices[i].id),
                  device: shownDevices[i],
                  selected: snapshot.selectedDeviceId == shownDevices[i].id,
                  onSelect: () => _companion(
                    widget.companionBridge.selectDevice(shownDevices[i].id),
                  ),
                  onFavorite: () => _companion(
                    widget.companionBridge.setFavorite(
                      shownDevices[i].id,
                      !shownDevices[i].favorite,
                    ),
                  ),
                ),
            ],
          ),
      ],
    ];
    final playbackPage = <Widget>[
      Text('播放', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 4),
      Text('让手机的声音，在电脑继续。', style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: 20),
      GlassSurface(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 8,
          ),
          leading: const Icon(Icons.laptop_rounded),
          title: Text(selected?.name ?? '尚未选择电脑'),
          subtitle: const Text('所选电脑 · 点击更换'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() => _page = 1),
        ),
      ),
      const SizedBox(height: 16),
      ...accessPrompt,
      if (snapshot.permission && snapshot.bluetoothEnabled) ...[
        GlassSurface(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                AnimatedSwitcher(
                  duration: _motionDuration(context),
                  layoutBuilder: (current, _) =>
                      current ?? const SizedBox.shrink(),
                  child: Column(
                    key: ValueKey(primaryTitle),
                    children: [
                      AudioHalo(
                        active: mediaPlaying || openedForThisPhone,
                        icon: mediaPlaying
                            ? Icons.graphic_eq
                            : Icons.bluetooth_audio,
                      ),
                      const SizedBox(height: 16),
                      ConnectionStatusLabel(
                        key: const Key('primary-media-status'),
                        state: mediaState,
                        label: primaryTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  selected == null
                      ? snapshot.devices.any(
                              (d) => d.a2dpStateKnown && d.a2dpConnected,
                            )
                            ? '系统已有蓝牙媒体连接，请选择对应电脑以同步接收状态。'
                            : '请选择电脑以查看本机蓝牙媒体状态。'
                      : openedForThisPhone
                      ? '电脑已确认本手机媒体路由已打开'
                      : !selected.a2dpStateKnown
                      ? '本机蓝牙媒体状态：正在确认'
                      : selected.a2dpPlaying
                      ? '本机蓝牙媒体：正在播放'
                      : selected.a2dpConnected
                      ? '本机蓝牙媒体：已连接到此电脑'
                      : '本机蓝牙媒体：未连接此电脑',
                  key: const Key('local-media-status'),
                  textAlign: TextAlign.center,
                ),
                if (!mediaPlaying &&
                    selected?.a2dpStateKnown == true &&
                    (selected?.a2dpConnected == true ||
                        selected?.a2dpPlaying == true))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '媒体服务已连接不等于当前正在向电脑播放。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (selected?.bonded == true &&
                    (snapshot.controlState ==
                            CompanionControlState.connecting ||
                        snapshot.controlState == CompanionControlState.idle ||
                        snapshot.controlState ==
                            CompanionControlState.unavailable))
                  TextButton.icon(
                    key: const Key('retry-status'),
                    onPressed:
                        statusRetrying ||
                            snapshot.controlState ==
                                CompanionControlState.connecting
                        ? null
                        : _retryStatus,
                    icon:
                        statusRetrying ||
                            snapshot.controlState ==
                                CompanionControlState.connecting
                        ? SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              value: MediaQuery.disableAnimationsOf(context)
                                  ? .5
                                  : null,
                            ),
                          )
                        : const Icon(Icons.sync),
                    label: Text(
                      statusRetrying ||
                              snapshot.controlState ==
                                  CompanionControlState.connecting
                          ? '正在同步…'
                          : '重试电脑状态',
                    ),
                  ),
                const SizedBox(height: 12),
                Column(
                  children: [
                    const Divider(height: 20),
                    AnimatedSwitcher(
                      duration: _motionDuration(context),
                      layoutBuilder: (current, _) =>
                          current ?? const SizedBox.shrink(),
                      child: Column(
                        key: ValueKey('${status.$1}|${status.$2}'),
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Flexible(
                                child: ConnectionStatusLabel(
                                  key: const Key('receiver-status'),
                                  state: receiverState,
                                  label: status.$1,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            status.$2,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (snapshot.outputSwitcherSupported)
          FilledButton.icon(
            key: const Key('output-switcher'),
            onPressed: () async {
              try {
                final shown = await widget.companionBridge.showOutputSwitcher();
                if (!shown && mounted) {
                  setState(() => error = '系统未打开媒体输出面板，请从正在播放 App 的通知中选择媒体输出。');
                }
              } catch (e) {
                if (mounted) setState(() => error = '$e');
              }
            },
            icon: const Icon(Icons.speaker_group),
            label: const Text('选择媒体输出'),
          )
        else
          const Text(
            'Android 12–13：请从正在播放 App 的通知中选择媒体输出。',
            textAlign: TextAlign.center,
          ),
      ],
    ];
    final settingsPage = <Widget>[
      Text('设置', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 4),
      const Text('快捷入口、应用更新与连接帮助'),
      const SizedBox(height: 20),
      _updateCard(),
      const SizedBox(height: 16),
      GlassSurface(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('快捷入口', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (selected != null)
                    TextButton.icon(
                      key: const Key('pin-shortcut'),
                      onPressed: () => _requestBool(
                        widget.companionBridge.pinShortcut(selected.id),
                        '已请求固定到桌面，请按系统提示确认。',
                      ),
                      icon: const Icon(Icons.push_pin_outlined),
                      label: const Text('固定到桌面'),
                    ),
                  TextButton.icon(
                    key: const Key('add-tile'),
                    onPressed: () => _requestBool(
                      widget.companionBridge.addQuickTile(),
                      '已请求添加快捷设置磁贴，请按系统提示确认。',
                    ),
                    icon: const Icon(Icons.dashboard_customize_outlined),
                    label: const Text('添加磁贴'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      GlassSurface(
        child: Column(
          children: [
            ExpansionTile(
              key: const PageStorageKey('connection-guide'),
              title: const Text('连接指南'),
              childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              children: [
                _Step(
                  done: selected?.bonded == true,
                  text: selected?.bonding == true
                      ? '正在配对电脑'
                      : '1. 与 Windows 电脑完成蓝牙配对。',
                ),
                _Step(
                  done: status.$1 == '电脑已准备好' || status.$1 == '连接已打开',
                  text: mediaPlaying && !openedForThisPhone
                      ? '2. 电脑接收状态待同步，不影响当前蓝牙播放。'
                      : '2. 在电脑端选择手机并开启接收。',
                ),
                _Step(
                  done: mediaPlaying || openedForThisPhone,
                  text: mediaPlaying
                      ? '3. 手机系统已报告向此电脑播放蓝牙媒体。'
                      : localConnected || openedForThisPhone
                      ? '3. 蓝牙媒体已连接；仍请确认媒体输出选择这台电脑。'
                      : '3. 在手机媒体输出中选择这台电脑。',
                ),
              ],
            ),
            ExpansionTile(
              key: const PageStorageKey('troubleshooting'),
              initiallyExpanded: false,
              title: const Text('测试与排障'),
              childrenPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              children: [
                const Text('4. 播放测试音并由你确认是否听到。'),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const Key('test-tone'),
                  onPressed: busy ? null : _toggleTone,
                  icon: Icon(tone ? Icons.stop : Icons.volume_up),
                  label: Text(tone ? '停止测试音' : '播放 2.5 秒测试音'),
                ),
                const SizedBox(height: 12),
                Text(
                  '测试音自动停止；路由已连接也不代表一定有声音。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  key: const Key('android-settings'),
                  onPressed: () async {
                    try {
                      await widget.routeBridge.openBluetoothSettings();
                    } catch (e) {
                      if (mounted) setState(() => error = '$e');
                    }
                  },
                  icon: const Icon(Icons.settings_bluetooth),
                  label: const Text('故障时打开系统蓝牙设置'),
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: toneStarted
                          ? () => setState(() => heard = true)
                          : null,
                      child: const Text('在电脑上听到了'),
                    ),
                    TextButton(
                      onPressed: toneStarted
                          ? () => setState(() => heard = false)
                          : null,
                      child: const Text('未听到'),
                    ),
                  ],
                ),
                if (heard != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(heard! ? '已人工确认听到测试音。' : '请检查电脑接收、媒体输出和音量后重试。'),
                  ),
              ],
            ),
          ],
        ),
      ),
    ];
    return Column(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                key: PageStorageKey('android-page-$_page'),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...[playbackPage, devicePage, settingsPage][_page],
                    if (error != null)
                      _PageNotice(
                        label: '操作失败：$error',
                        icon: Icons.error_outline,
                        isError: true,
                      ),
                    if (info != null)
                      _PageNotice(label: info!, icon: Icons.info_outline),
                    if (snapshot.message.isNotEmpty)
                      _PageNotice(
                        key: const Key('computer-message'),
                        label: '电脑消息：${snapshot.message}',
                        icon: Icons.chat_bubble_outline_rounded,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        NavigationBar(
          key: const Key('android-navigation'),
          selectedIndex: _page,
          onDestinationSelected: (index) => setState(() => _page = index),
          destinations: const [
            NavigationDestination(
              key: Key('nav-playback'),
              icon: Icon(Icons.headphones_outlined),
              selectedIcon: Icon(Icons.headphones),
              label: '播放',
            ),
            NavigationDestination(
              key: Key('nav-devices'),
              icon: Icon(Icons.devices_outlined),
              selectedIcon: Icon(Icons.devices),
              label: '设备',
            ),
            NavigationDestination(
              key: Key('nav-settings'),
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置',
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _requestBool(Future<bool> request, String success) async {
    try {
      final accepted = await request;
      if (mounted) {
        setState(() {
          if (accepted) {
            info = success;
            error = null;
          } else {
            error = '系统未接受请求；Android 12–12L 请编辑快捷设置并手动添加“AudioShare”。';
            info = null;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Widget _updateCard() {
    final update = updateInfo;
    final progress = downloadProgress;
    final fraction = progress?.fraction;
    final title = updateChecking
        ? '正在检查更新…'
        : updateInstalling
        ? progress?.installing == true
              ? '下载完成，正在打开安装器…'
              : progress?.received == 0
              ? '正在连接下载…'
              : '正在下载更新…'
        : updateError ??
              (update?.message.isNotEmpty == true
                  ? update!.message
                  : update?.available == true
                  ? '发现新版本 ${update!.latestVersion}'
                  : update == null
                  ? '尚未检查更新'
                  : '当前没有可用的 Android 更新');
    String mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return GlassSurface(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '应用更新',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  key: const Key('check-update'),
                  tooltip: '检查更新',
                  onPressed: updateChecking || updateInstalling
                      ? null
                      : _checkForUpdate,
                  icon: updateChecking
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(title),
            if (update != null) ...[
              const SizedBox(height: 6),
              Text(
                '当前版本 ${update.currentVersion}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (updateInstalling) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                key: const Key('update-download-progress'),
                value: fraction,
                minHeight: 6,
                borderRadius: BorderRadius.circular(6),
                semanticsLabel: '更新下载进度',
                semanticsValue: fraction == null
                    ? '已下载 ${mb(progress?.received ?? 0)}'
                    : '${(fraction * 100).floor()}%',
              ),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 16,
                runSpacing: 6,
                children: [
                  Text(
                    fraction == null
                        ? '已下载 ${mb(progress?.received ?? 0)}'
                        : '${mb(progress!.received)} / ${mb(progress.total)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (fraction != null)
                    Text(
                      '${(fraction * 100).floor()}%',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                ],
              ),
            ],
            if (update?.available == true) ...[
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('install-update'),
                onPressed: updateInstalling || updateChecking
                    ? null
                    : _installUpdate,
                child: Text(
                  updateInstalling
                      ? '正在更新…'
                      : updateError != null
                      ? '重新下载'
                      : '立即更新',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PageNotice extends StatelessWidget {
  const _PageNotice({
    super.key,
    required this.label,
    required this.icon,
    this.isError = false,
  });
  final String label;
  final IconData icon;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.error : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: (isError ? scheme.error : scheme.primary).withValues(
            alpha: .06,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends StatefulWidget {
  const _DeviceCard({
    super.key,
    required this.device,
    required this.selected,
    required this.onSelect,
    required this.onFavorite,
  });
  final CompanionDevice device;
  final bool selected;
  final VoidCallback onSelect, onFavorite;

  @override
  State<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<_DeviceCard> {
  bool pressed = false;

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final selected = widget.selected;
    final connected =
        device.a2dpStateKnown && (device.a2dpConnected || device.a2dpPlaying);
    final indicator = connected
        ? ConnectionIndicatorState.connected
        : device.bonding
        ? ConnectionIndicatorState.pending
        : device.a2dpStateKnown
        ? ConnectionIndicatorState.disconnected
        : ConnectionIndicatorState.unknown;
    final label = connected
        ? '媒体已连接'
        : device.bonding
        ? '正在配对'
        : device.a2dpStateKnown
        ? '媒体已断开'
        : device.bonded
        ? '已配对'
        : device.recent
        ? '最近使用'
        : '附近设备';
    final width = ((MediaQuery.sizeOf(context).width - 64) / 2).clamp(
      128.0,
      170.0,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: width,
        maxWidth: width,
        minHeight: 144,
      ),
      child: InkWell(
        key: Key('device-${device.id}'),
        borderRadius: BorderRadius.circular(28),
        onHighlightChanged: (value) => setState(() => pressed = value),
        onTap: widget.onSelect,
        child: AnimatedScale(
          key: Key('device-scale-${device.id}'),
          scale: pressed ? .96 : 1,
          duration: _motionDuration(context),
          curve: Curves.easeOutBack,
          child: AnimatedContainer(
            duration: _motionDuration(context),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: .08)
                  : Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: .55),
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Stack(
              children: [
                Column(
                  children: [
                    const SizedBox(height: 6),
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [
                                Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: .18),
                                Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: .04),
                              ],
                            ),
                          ),
                        ),
                        Icon(
                          Icons.laptop_chromebook,
                          size: 28,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    ConnectionStatusLabel(
                      state: indicator,
                      label: label,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    if (device.recent)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '最近使用',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                  ],
                ),
                Positioned(
                  right: -8,
                  top: -8,
                  child: IconButton(
                    tooltip: device.favorite ? '取消收藏' : '收藏',
                    onPressed: widget.onFavorite,
                    icon: Icon(
                      device.favorite ? Icons.favorite : Icons.favorite_border,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.done, required this.text});
  final bool done;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        AnimatedSwitcher(
          duration: _motionDuration(context),
          child: Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            key: ValueKey(done),
            color: done ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
