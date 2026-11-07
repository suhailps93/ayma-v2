
import 'package:ayma_flutter/services/copilot_highlight.dart';
import 'package:ayma_flutter/services/copilot_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ayma/copilot');
  final calls = <MethodCall>[];

  String? installerValue;

  CopilotService makeService() =>
      CopilotService(channel: channel, debugSupportedOverride: true);

  setUp(() {
    calls.clear();
    installerValue = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'canDrawOverlays':
          return true;
        case 'requestCapture':
          return true;
        case 'isSharing':
          return true;
        case 'installerPackage':
          return installerValue;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  MethodCall frameCall({double luminance = 120}) => MethodCall('onFrame', {
        'bytes': Uint8List.fromList([1, 2, 3]),
        'width': 720,
        'height': 1600,
        'displayWidth': 1080,
        'displayHeight': 2400,
        'meanLuminance': luminance,
      });

  test('wasSideloaded reads the installer package', () async {
    final s = makeService();
    installerValue = 'com.android.vending';
    expect(await s.wasSideloaded(), isFalse);
    installerValue = 'com.android.chrome';
    expect(await s.wasSideloaded(), isTrue);
    installerValue = null;
    expect(await s.wasSideloaded(), isTrue);
    s.dispose();
  });

  test('openAppInfo goes through the channel', () async {
    final s = makeService();
    await s.openAppInfo();
    expect(calls.map((c) => c.method), contains('openAppInfo'));
    s.dispose();
  });

  test('requestCaptureAndStart flips sharing on consent', () async {
    final s = makeService();
    expect(await s.requestCaptureAndStart(), isTrue);
    expect(s.isSharing, isTrue);
    expect(calls.map((c) => c.method), contains('requestCapture'));
    s.dispose();
  });

  test('a frame lands in latestFrame and unlocks canAsk', () async {
    final s = makeService();
    await s.requestCaptureAndStart();
    await s.debugHandleNativeCall(frameCall());
    expect(s.latestFrame, isNotNull);
    expect(s.latestFrame!.displayWidth, 1080);
    expect(s.canAsk, isTrue);
    s.dispose();
  });

  test('a black frame is dropped and secure-pauses the share', () async {
    final s = makeService();
    await s.requestCaptureAndStart();
    await s.debugHandleNativeCall(frameCall(luminance: 0));
    expect(s.latestFrame, isNull);
    expect(s.securePaused, isTrue);
    expect(s.canAsk, isFalse);
    s.dispose();
  });

  test('onSecurePause clears the held frame; resume needs a fresh frame',
      () async {
    final s = makeService();
    await s.requestCaptureAndStart();
    await s.debugHandleNativeCall(frameCall());
    expect(s.canAsk, isTrue);
    await s.debugHandleNativeCall(
      const MethodCall('onSecurePause', {'paused': true}),
    );
    expect(s.securePaused, isTrue);
    expect(s.latestFrame, isNull);
    await s.debugHandleNativeCall(
      const MethodCall('onSecurePause', {'paused': false}),
    );
    expect(s.securePaused, isFalse);
    expect(s.canAsk, isFalse); // no frame held until the next one arrives
    s.dispose();
  });

  test('showHighlight maps normalized coords to display pixels', () async {
    final s = makeService();
    await s.showHighlight(
      const CopilotTarget(
        found: true,
        x: 0.5,
        y: 0.5,
        w: 0.2,
        h: 0.1,
        label: 'Send',
      ),
      geometry: const CopilotGeometry(
        displayWidthPx: 1080,
        displayHeightPx: 2400,
        frameWidthPx: 1080,
        frameHeightPx: 2400,
      ),
    );
    final call = calls.singleWhere((c) => c.method == 'showHighlight');
    final args = call.arguments as Map<dynamic, dynamic>;
    expect(args['x'], closeTo(540, 0.001));
    expect(args['y'], closeTo(1200, 0.001));
    expect(args['w'], closeTo(216, 0.001));
    expect(args['h'], closeTo(240, 0.001));
    expect(args['label'], 'Send');
    s.dispose();
  });

  test('showHighlight is a no-op for a miss', () async {
    final s = makeService();
    await s.showHighlight(
      const CopilotTarget(found: false, say: 'not here'),
      geometry: const CopilotGeometry(
        displayWidthPx: 1080,
        displayHeightPx: 2400,
        frameWidthPx: 1080,
        frameHeightPx: 2400,
      ),
    );
    expect(calls.where((c) => c.method == 'showHighlight'), isEmpty);
    s.dispose();
  });

  test('stopSharing resets the session and notifies native', () async {
    final s = makeService();
    await s.requestCaptureAndStart();
    await s.debugHandleNativeCall(frameCall());
    await s.stopSharing();
    expect(s.isSharing, isFalse);
    expect(s.latestFrame, isNull);
    expect(calls.map((c) => c.method), contains('stopSharing'));
    s.dispose();
  });

  test('onSharingStopped from native resets everything', () async {
    final s = makeService();
    await s.requestCaptureAndStart();
    await s.debugHandleNativeCall(frameCall());
    await s.debugHandleNativeCall(const MethodCall('onSharingStopped'));
    expect(s.isSharing, isFalse);
    expect(s.latestFrame, isNull);
    s.dispose();
  });
}
