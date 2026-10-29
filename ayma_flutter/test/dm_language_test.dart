import 'package:ayma_flutter/utils/dm_language.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dominantScript', () {
    test('plain English is Latin', () {
      expect(dominantScript('hello'), 'latin');
      expect(dominantScript('hey sexy'), 'latin');
    });

    test('accented Latin (Spanish/French) is still Latin', () {
      expect(dominantScript('¿Cómo estás?'), 'latin');
      expect(dominantScript('Bonjour mon ami'), 'latin');
    });

    test('Malayalam is detected as its own script', () {
      expect(dominantScript('ഹായ് സുഖമാണോ'), 'malayalam');
    });

    test('other non-Latin scripts are detected', () {
      expect(dominantScript('Привет'), 'cyrillic');
      expect(dominantScript('مرحبا'), 'arabic');
      expect(dominantScript('こんにちは'), 'japanese');
    });

    test('script-less noise has no dominant script', () {
      expect(dominantScript('123 👍 !!!'), 'none');
      expect(dominantScript(''), 'none');
      expect(dominantScript('😀😀😀'), 'none');
    });
  });

  group('scriptOfLang', () {
    test('Latin languages', () {
      expect(scriptOfLang('en'), 'latin');
      expect(scriptOfLang('es'), 'latin');
      expect(scriptOfLang('fr'), 'latin');
      expect(scriptOfLang('en-US'), 'latin');
      expect(scriptOfLang(''), 'latin'); // unknown → Latin default
    });

    test('non-Latin languages', () {
      expect(scriptOfLang('ml'), 'malayalam');
      expect(scriptOfLang('ar'), 'arabic');
      expect(scriptOfLang('ru'), 'cyrillic');
    });
  });

  group('isForeignScript', () {
    test('same-script text (English for an English reader) is not foreign', () {
      // Short or long, Latin text is ambiguous, not reliably foreign — resolved
      // by the backend, never offered on script alone.
      expect(isForeignScript('hello', 'en'), isFalse);
      expect(isForeignScript('hey sexy', 'en'), isFalse);
      expect(isForeignScript('¿Cómo estás?', 'en'), isFalse);
    });

    test('different-script text is reliably foreign even when short', () {
      expect(isForeignScript('ഹായ്', 'en'), isTrue);
      expect(isForeignScript('Привет', 'en'), isTrue);
    });

    test('noise is never foreign', () {
      expect(isForeignScript('👍', 'en'), isFalse);
      expect(isForeignScript('123', 'en'), isFalse);
    });

    test("a non-Latin reader sees Latin messages as foreign", () {
      expect(isForeignScript('hello', 'ml'), isTrue);
      expect(isForeignScript('ഹായ്', 'ml'), isFalse);
    });
  });
}
