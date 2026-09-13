import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final mode in [ComposerMode.text]) {
    testWidgets('text composer suppresses inherited fill and focused border', (
      tester,
    ) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      final level = ValueNotifier<double>(1);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            extensions: const [AymaTokens.light],
            inputDecorationTheme: const InputDecorationTheme(
              filled: true,
              fillColor: AymaColors.lightBgElev,
              focusedBorder: OutlineInputBorder(),
            ),
          ),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey('composer'),
                child: SizedBox(
                  width: 390,
                  height: 56,
                  child: ChatComposer(
                    mode: mode,
                    controller: controller,
                    focusNode: focus,
                    canSend: true,
                    onSend: () {},
                    onAttach: () {},
                    onMicPressed: () {},
                    onStopPressed: () {},
                    onMuteTap: () {},
                    muted: false,
                    userAmplitude: level,
                    aiAmplitude: level,
                    statusLabel: mode == ComposerMode.listening
                        ? 'Listening…'
                        : 'Ayma is speaking…',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (var frame = 0; frame < 45; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (mode == ComposerMode.text) {
        // Exercise the actual filled app theme, including keyboard focus.
        await tester.tap(find.byType(TextField));
        await tester.pump(const Duration(milliseconds: 300));
        final decorator = tester.widget<InputDecorator>(
          find.byType(InputDecorator),
        );
        expect(decorator.decoration.filled, false);
        expect(decorator.decoration.focusedBorder, InputBorder.none);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
      level.dispose();
    });
  }
}
