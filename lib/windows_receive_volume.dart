import 'dart:async';
import 'package:flutter/material.dart';
import 'app_style.dart';
import 'platform/external_route_bridge.dart';

class WindowsReceiveVolume extends StatefulWidget {
  const WindowsReceiveVolume({
    super.key,
    required this.bridge,
    required this.connected,
  });
  final ExternalRouteBridge bridge;
  final bool connected;
  @override
  State<WindowsReceiveVolume> createState() => _WindowsReceiveVolumeState();
}

class _WindowsReceiveVolumeState extends State<WindowsReceiveVolume> {
  MediaVolume? volume;
  double? draft;
  bool busy = false;
  bool writing = false;
  bool dragging = false;
  int? queued;
  Timer? throttle;
  int epoch = 0;
  String? error;

  @override
  void initState() {
    super.initState();
    if (widget.connected) refresh();
  }

  @override
  void didUpdateWidget(covariant WindowsReceiveVolume oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connected != widget.connected) {
      epoch++;
      volume = null;
      draft = null;
      busy = false;
      writing = false;
      dragging = false;
      queued = null;
      throttle?.cancel();
      throttle = null;
      error = null;
      if (widget.connected) refresh();
    }
  }

  @override
  void dispose() {
    epoch++;
    throttle?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (busy || writing || dragging || !widget.connected) return;
    final request = ++epoch;
    throttle?.cancel();
    throttle = null;
    queued = null;
    setState(() {
      busy = true;
      error = null;
      draft = null;
    });
    try {
      final result = await widget.bridge.getReceiveVolume();
      if (mounted && request == epoch) setState(() => volume = result);
    } catch (_) {
      if (mounted && request == epoch) {
        setState(() {
          volume = null;
          error = '读取或调整失败，请刷新重试。';
        });
      }
    } finally {
      if (mounted && request == epoch) setState(() => busy = false);
    }
  }

  void queueVolume(double value, {bool released = false}) {
    setState(() {
      draft = value;
      dragging = !released;
      queued = value.round();
      error = null;
    });
    if (released) {
      throttle?.cancel();
      throttle = null;
      unawaited(flush());
    } else if (!writing && throttle == null) {
      schedule();
    }
  }

  void schedule() {
    throttle = Timer(const Duration(milliseconds: 50), () {
      throttle = null;
      unawaited(flush());
    });
  }

  Future<void> flush() async {
    if (writing || queued == null || !widget.connected) return;
    final request = epoch;
    final value = queued!;
    queued = null;
    writing = true;
    try {
      final result = await widget.bridge.setReceiveVolume(value);
      if (!mounted || request != epoch) return;
      setState(() {
        volume = result;
        if (!result.available) {
          queued = null;
          dragging = false;
          draft = null;
        } else if (!dragging && queued == null) {
          draft = null;
        }
      });
    } catch (_) {
      if (!mounted || request != epoch) return;
      setState(() {
        volume = null;
        queued = null;
        dragging = false;
        draft = null;
        error = '读取或调整失败，请刷新重试。';
      });
    } finally {
      if (mounted && request == epoch) {
        setState(() => writing = false);
        if (queued != null) {
          if (dragging) {
            schedule();
          } else {
            unawaited(flush());
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.connected && volume?.available == true && !busy;
    final value = draft ?? (volume?.current ?? 100).clamp(0, 100).toDouble();
    return GlassSurface(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.volume_up_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '接收音量',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    volume?.available == true ? '${value.round()}%' : '—',
                    textAlign: TextAlign.right,
                  ),
                ),
                IconButton(
                  key: const Key('refresh-receive-volume'),
                  tooltip: '刷新接收音量',
                  onPressed: widget.connected && !busy && !writing && !dragging
                      ? refresh
                      : null,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            RepaintBoundary(
              child: Slider(
                key: const Key('receive-volume-slider'),
                value: value,
                min: 0,
                max: 100,
                label: '${value.round()}%',
                onChanged: enabled ? (value) => queueVolume(value) : null,
                onChangeEnd: enabled
                    ? (value) => queueVolume(value, released: true)
                    : null,
              ),
            ),
            Text(
              error ??
                  (widget.connected
                      ? volume?.message ?? '正在查找手机接收声道…'
                      : '连接手机后可调节电脑接收的声音。'),
            ),
            const SizedBox(height: 6),
            Text(
              '0% 静音 · 100% 原始音量。手机端是否联动尚待实测；停止接收或退出时恢复原值。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
