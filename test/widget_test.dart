import 'package:audioshare/main.dart';
import 'package:audioshare/platform/windows_audio_player.dart';
import 'package:audioshare/protocol/audio_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders AudioShare shell and core controls', (tester) async {
    await tester.pumpWidget(const AudioShareApp());

    expect(find.text('AudioShare'), findsOneWidget);
    expect(find.text('Android 推流'), findsOneWidget);
    expect(find.text('Windows 接收'), findsOneWidget);
    expect(find.text('连接设置'), findsOneWidget);
  });

  testWidgets('can switch to Windows receiver mode', (tester) async {
    await tester.pumpWidget(const AudioShareApp());

    await tester.tap(find.text('Windows 接收'));
    await tester.pumpAndSettle();

    expect(find.text('Windows 音频接收'), findsOneWidget);
    expect(find.text('开始监听'), findsOneWidget);
  });

  test('controller validates port range', () {
    final controller = AudioShareController();

    controller.updatePort('70000');

    expect(controller.status, LinkStatus.error);
    expect(controller.lastMessage, contains('端口'));
  });

  test('controller accepts Android pairing code entry and Windows refresh', () {
    final controller = AudioShareController();

    controller.updatePairingCode('123456');
    expect(controller.pairingCode, '123456');

    controller.refreshPairingCode();
    expect(controller.pairingCode, matches(RegExp(r'^\d{3}-\d{3}$')));
  });

  test('Windows audio player is inert outside Windows', () {
    final player = WindowsAudioPlayer();

    final devices = player.listOutputDevices();
    expect(devices, isNotEmpty);
    expect(devices.first.id, 'default');

    final started = player.start(
      sampleRate: 48000,
      channels: 2,
      frameMs: 20,
      bitrateKbps: 96,
      bufferMs: 80,
    );

    if (started) {
      player.stop();
    } else {
      expect(player.isStarted, isFalse);
    }
  });

  test('audio packet codec rejects wrong auth keys', () {
    const packet = AudioPacket(
      sessionId: 7,
      sequence: 42,
      timestampMs: 1234,
      payload: [1, 2, 3, 4],
    );

    final encoded = AudioPacketCodec.encode(packet, 'secret');
    final decoded = AudioPacketCodec.decode(encoded, 'secret');

    expect(decoded.sessionId, packet.sessionId);
    expect(decoded.sequence, packet.sequence);
    expect(decoded.timestampMs, packet.timestampMs);
    expect(decoded.payload, packet.payload);
    expect(
      () => AudioPacketCodec.decode(encoded, 'wrong'),
      throwsFormatException,
    );
  });

  test('audio packet codec rejects malformed packet lengths', () {
    const packet = AudioPacket(
      sessionId: 7,
      sequence: 42,
      timestampMs: 1234,
      payload: [1, 2, 3, 4],
    );

    final encoded = AudioPacketCodec.encode(packet, 'secret');

    expect(
      () => AudioPacketCodec.decode([...encoded, 0], 'secret'),
      throwsFormatException,
    );
    expect(
      () => AudioPacketCodec.decode(
        encoded.sublist(0, encoded.length - 1),
        'secret',
      ),
      throwsFormatException,
    );
  });
}
