import 'dart:convert' show utf8;
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _CreatePlayerNative =
    Pointer<Void> Function(
      Uint32,
      Uint16,
      Uint16,
      Uint16,
      Uint16,
      Pointer<Uint8>,
      IntPtr,
    );
typedef _CreatePlayerDart =
    Pointer<Void> Function(int, int, int, int, int, Pointer<Uint8>, int);
typedef _PushPacketNative =
    Int32 Function(Pointer<Void>, Uint64, Uint64, Pointer<Uint8>, IntPtr);
typedef _PushPacketDart =
    int Function(Pointer<Void>, int, int, Pointer<Uint8>, int);
typedef _ListOutputDevicesNative =
    IntPtr Function(Pointer<_NativeOutputDevice>, IntPtr);
typedef _ListOutputDevicesDart =
    int Function(Pointer<_NativeOutputDevice>, int);
typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);

final class _NativeOutputDevice extends Struct {
  @Array(64)
  external Array<Uint8> id;

  @Array(256)
  external Array<Uint8> name;

  @Uint8()
  external int isDefault;
}

class WindowsOutputDevice {
  const WindowsOutputDevice({
    required this.id,
    required this.name,
    required this.isDefault,
  });

  final String id;
  final String name;
  final bool isDefault;
}

class WindowsAudioPlayer {
  static const fallbackOutputDevices = [
    WindowsOutputDevice(id: 'default', name: '默认输出设备', isDefault: true),
  ];

  DynamicLibrary? _library;
  Pointer<Void>? _player;
  _CreatePlayerDart? _createPlayer;
  _PushPacketDart? _pushPacket;
  _ListOutputDevicesDart? _listOutputDevices;
  _DestroyDart? _destroy;

  String? lastError;

  bool get isStarted => _player != null && _player != nullptr;

  bool start({
    required int sampleRate,
    required int channels,
    required int frameMs,
    required int bitrateKbps,
    required int bufferMs,
    String outputDevice = 'default',
  }) {
    if (!Platform.isWindows) return false;
    if (isStarted) return true;

    final outputDeviceBytes = utf8.encode(outputDevice);
    final outputDevicePointer = outputDevice
        .toNativeUtf8(allocator: calloc)
        .cast<Uint8>();
    try {
      _loadLibrary();
      final player = _createPlayer!(
        sampleRate,
        channels,
        frameMs,
        bitrateKbps,
        bufferMs,
        outputDevicePointer,
        outputDeviceBytes.length,
      );
      if (player == nullptr) {
        lastError = '无法打开 Windows 输出设备“$outputDevice”或创建 Opus 解码器';
        return false;
      }
      _player = player;
      lastError = null;
      return true;
    } catch (error) {
      lastError = 'Windows 原生播放器加载失败：$error';
      return false;
    } finally {
      calloc.free(outputDevicePointer);
    }
  }

  List<WindowsOutputDevice> listOutputDevices() {
    if (!Platform.isWindows) return fallbackOutputDevices;

    try {
      _loadLibrary();
      final list = _listOutputDevices;
      if (list == null) return fallbackOutputDevices;

      const capacity = 32;
      final devices = calloc<_NativeOutputDevice>(capacity);
      try {
        final count = list(devices, capacity).clamp(0, capacity);
        final parsed = <WindowsOutputDevice>[
          ...fallbackOutputDevices,
          for (var index = 0; index < count; index += 1)
            WindowsOutputDevice(
              id: _fixedUtf8String(devices[index].id, 64),
              name: _fixedUtf8String(devices[index].name, 256),
              isDefault: devices[index].isDefault != 0,
            ),
        ];
        return parsed
            .where((device) => device.name.isNotEmpty)
            .fold(<String, WindowsOutputDevice>{}, (map, device) {
              map.putIfAbsent(device.id, () => device);
              return map;
            })
            .values
            .toList(growable: false);
      } finally {
        calloc.free(devices);
      }
    } catch (error) {
      lastError = 'Windows 输出设备列表加载失败：$error';
      return fallbackOutputDevices;
    }
  }

  int pushPacket({
    required int sequence,
    required int timestampMs,
    required Uint8List payload,
  }) {
    final player = _player;
    final push = _pushPacket;
    if (player == null || player == nullptr || push == null) {
      lastError = 'Windows 原生播放器未启动';
      return -1;
    }

    final buffer = calloc<Uint8>(payload.length);
    try {
      buffer.asTypedList(payload.length).setAll(0, payload);
      final result = push(
        player,
        sequence,
        timestampMs,
        buffer,
        payload.length,
      );
      if (result < 0) {
        lastError = switch (result) {
          -2 => 'Opus 解码失败',
          -3 => 'Windows 输出设备写入失败',
          _ => 'Windows 原生播放器错误 $result',
        };
        return result;
      }
      lastError = null;
      return result;
    } finally {
      calloc.free(buffer);
    }
  }

  void stop() {
    final player = _player;
    if (player != null && player != nullptr) {
      _destroy?.call(player);
    }
    _player = null;
  }

  void _loadLibrary() {
    if (_library != null) return;
    final library = DynamicLibrary.open('audioshare_core.dll');
    _library = library;
    _createPlayer = library
        .lookupFunction<_CreatePlayerNative, _CreatePlayerDart>(
          'audioshare_player_create',
        );
    _pushPacket = library.lookupFunction<_PushPacketNative, _PushPacketDart>(
      'audioshare_player_push_packet',
    );
    try {
      _listOutputDevices = library
          .lookupFunction<_ListOutputDevicesNative, _ListOutputDevicesDart>(
            'audioshare_list_output_devices',
          );
    } catch (_) {
      _listOutputDevices = null;
    }
    _destroy = library.lookupFunction<_DestroyNative, _DestroyDart>(
      'audioshare_player_destroy',
    );
  }

  static String _fixedUtf8String(Array<Uint8> bytes, int length) {
    final values = <int>[];
    for (var index = 0; index < length; index += 1) {
      final value = bytes[index];
      if (value == 0) break;
      values.add(value);
    }
    return utf8.decode(values, allowMalformed: true);
  }
}
