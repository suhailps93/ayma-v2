import 'dart:typed_data';

import 'package:ayma_flutter/services/assist_context.dart';
import 'package:flutter_test/flutter_test.dart';

AssistSnapshot _snap({
  String pkg = 'com.example.shop',
  List<String> texts = const ['Checkout', 'Total \$42', 'Pay now'],
  bool allowed = true,
  bool screenshot = false,
  String webUri = '',
}) =>
    AssistSnapshot(
      foregroundPackage: pkg,
      webUri: webUri,
      texts: texts,
      hasScreenshot: screenshot,
      screenDataAllowed: allowed,
      capturedAtMillis: DateTime.now().millisecondsSinceEpoch,
      source: 'voice_interaction',
    );

void main() {
  group('AssistSnapshot.fromMap / AssistCapture.fromMap', () {
    test('parses the native wire shape, including screenshot bytes', () {
      final capture = AssistCapture.fromMap({
        'foregroundPackage': 'com.android.chrome',
        'webUri': 'https://example.com/cart',
        'structuredData': '',
        'texts': ['Cart', 'Checkout'],
        'screenshotBytes': Uint8List.fromList([1, 2, 3]),
        'screenshotWidth': 720,
        'screenshotHeight': 1280,
        'capturedAtMillis': 123,
        'screenDataAllowed': true,
        'source': 'voice_interaction',
      });
      expect(capture.snapshot.foregroundPackage, 'com.android.chrome');
      expect(capture.snapshot.texts, ['Cart', 'Checkout']);
      expect(capture.snapshot.hasScreenshot, isTrue);
      expect(capture.snapshot.screenshotWidth, 720);
      expect(capture.screenshotBytes, [1, 2, 3]);
    });

    test('a null screenshot and missing keys parse as an empty summon', () {
      final snap = AssistSnapshot.fromMap(const {});
      expect(snap.hasScreenContent, isFalse);
      expect(snap.screenDataAllowed, isFalse);
      expect(snap.friendlyAppName, 'another app');
    });
  });

  group('derived text', () {
    test('friendlyAppName title-cases the last package segment', () {
      expect(_snap().friendlyAppName, 'Shop');
      expect(_snap(pkg: 'com.android.chrome').friendlyAppName, 'Chrome');
      expect(_snap(pkg: '').friendlyAppName, 'another app');
    });

    test('visibleText de-duplicates case-insensitively and caps', () {
      final snap = _snap(texts: ['One', 'one', 'Two', 'Three']);
      expect(snap.visibleText(), 'One\nTwo\nThree');
      final capped = _snap(texts: ['aaaa', 'bbbb', 'cccc']).visibleText(
        maxChars: 9,
      );
      expect(capped.length, lessThanOrEqualTo(9));
    });

    test('describe names the app and previews the screen', () {
      final text = _snap().describe();
      expect(text, contains('Shop'));
      expect(text, contains('Checkout'));
    });

    test('describe is honest when Android shared nothing', () {
      final text = _snap(allowed: false, texts: const []).describe();
      expect(text, contains('did not share'));
    });

    test('chatScreenParams ride the external_app screen channel', () {
      final params = _snap().chatScreenParams();
      expect(params.screen, 'external_app');
      expect(params.subjectName, 'Shop');
      expect(params.note, 'com.example.shop');
      expect(params.visible, contains('Pay now'));
      expect(params.detail, contains('Checkout'));
    });

    test('questionWithContext embeds a capped screen excerpt', () {
      final q = _snap().questionWithContext('What do I tap?');
      expect(q, startsWith('What do I tap?'));
      expect(q, contains('On my screen in Shop'));
      expect(_snap(texts: const [], screenshot: false)
          .questionWithContext('Hi'), 'Hi');
    });
  });

  group('privacy copy', () {
    test('pins the load-bearing claims', () {
      expect(AssistPrivacy.sessionNote, contains('only because you summoned'));
      expect(AssistPrivacy.sessionNote, contains('never stored'));
      expect(AssistPrivacy.noScreenDataNote, contains('Use screen and app data'));
      expect(AssistPrivacy.settingsBlurb, contains('never stored'));
    });
  });

  group('AssistantSessionStore', () {
    tearDown(() => AssistantSessionStore.instance.reset());

    test('holds and clears a capture', () {
      final capture = AssistCapture(snapshot: _snap());
      AssistantSessionStore.instance.hold(capture);
      expect(AssistantSessionStore.instance.current, same(capture));
      AssistantSessionStore.instance.clear();
      expect(AssistantSessionStore.instance.current, isNull);
    });

    test('a stale capture reads as absent', () {
      final old = AssistSnapshot(
        capturedAtMillis: DateTime.now().millisecondsSinceEpoch -
            AssistantSessionStore.maxAge.inMilliseconds -
            1000,
        screenDataAllowed: true,
      );
      AssistantSessionStore.instance.hold(AssistCapture(snapshot: old));
      expect(AssistantSessionStore.instance.current, isNull);
    });
  });
}
