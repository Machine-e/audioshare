import 'package:audioshare/main.dart';
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
}
