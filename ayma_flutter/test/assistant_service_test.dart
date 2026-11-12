import 'package:ayma_flutter/services/assist_context.dart';
import 'package:ayma_flutter/services/assistant_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AssistantService.channelName);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    AssistantSessionStore.instance.reset();
  });

  AssistantService service() => AssistantService(channel: channel);

  test('isDefaultAssistant reads the platform value', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'isDefaultAssistant');
      return true;
    });
    expect(await service().isDefaultAssistant(), isTrue);
  });

  test('platform errors read as dormant, never throw', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'NOPE');
    });
    final s = service();
    expect(await s.isDefaultAssistant(), isFalse);
    expect(await s.openDefaultAssistantSettings(), isFalse);
    expect(await s.takePendingAssist(), isNull);
    expect(await s.hasPendingAssist(), isFalse);
  });

  test('a missing plugin reads as dormant, never throws', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final s = service();
    expect(await s.isDefaultAssistant(), isFalse);
    expect(await s.takePendingAssist(), isNull);
  });

  test('takePendingAssist parses a capture with screenshot bytes', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'takePendingAssist') {
        return {
          'foregroundPackage': 'com.example.shop',
          'texts': ['Checkout'],
          'screenshotBytes': Uint8List.fromList([9, 9]),
          'screenDataAllowed': true,
          'capturedAtMillis': 42,
        };
      }
      return null;
    });
    final capture = await service().takePendingAssist();
    expect(capture?.snapshot.foregroundPackage, 'com.example.shop');
    expect(capture?.screenshotBytes, [9, 9]);
  });

  test('bindSummons delivers the cold-start capture and holds it', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'takePendingAssist') {
        return {
          'foregroundPackage': 'com.example.shop',
          'texts': ['Hi'],
          'screenDataAllowed': true,
          'capturedAtMillis': DateTime.now().millisecondsSinceEpoch,
        };
      }
      return null;
    });
    AssistCapture? delivered;
    await service().bindSummons(onSummon: (c) => delivered = c);
    expect(delivered?.snapshot.foregroundPackage, 'com.example.shop');
    expect(
      AssistantSessionStore.instance.current?.snapshot.foregroundPackage,
      'com.example.shop',
    );
  });

  test('bindSummons with no pending summon stays quiet', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    var calls = 0;
    await service().bindSummons(onSummon: (_) => calls++);
    expect(calls, 0);
    expect(AssistantSessionStore.instance.current, isNull);
  });
}
