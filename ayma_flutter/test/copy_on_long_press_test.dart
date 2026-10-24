import 'package:ayma_flutter/widgets/copy_on_long_press.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('long-press copies the text and shows Copied; tap is untouched', (
    tester,
  ) async {
    String? clip;
    var taps = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clip = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CopyOnLongPress(
            text: 'hello there',
            child: GestureDetector(
              onTap: () => taps++,
              child: const Text('hello there'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('hello there'));
    expect(taps, 1);
    expect(clip, isNull);

    await tester.longPress(find.text('hello there'));
    await tester.pump();
    expect(clip, 'hello there');
    expect(find.text('Copied'), findsOneWidget);
  });
}
