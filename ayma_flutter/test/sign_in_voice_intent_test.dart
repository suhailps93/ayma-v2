import 'package:ayma_flutter/legal/sign_in_critical_consent.dart';
import 'package:ayma_flutter/services/sign_in_voice_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseSignInVoiceIntent', () {
    test('"open the terms and conditions" → openTerms', () {
      expect(parseSignInVoiceIntent('Open the terms and conditions please'),
          SignInVoiceIntent.openTerms);
      expect(parseSignInVoiceIntent('can you show me the terms of service'),
          SignInVoiceIntent.openTerms);
    });

    test('"open the privacy policy" → openPrivacy', () {
      expect(parseSignInVoiceIntent('open the privacy policy'),
          SignInVoiceIntent.openPrivacy);
      expect(parseSignInVoiceIntent('where is the privacy policy?'),
          SignInVoiceIntent.openPrivacy);
    });

    test('"open biometric information" (and face wording) → openBiometric', () {
      expect(parseSignInVoiceIntent('open biometric information'),
          SignInVoiceIntent.openBiometric);
      expect(parseSignInVoiceIntent('show me the face recognition page'),
          SignInVoiceIntent.openBiometric);
      expect(parseSignInVoiceIntent('can I see the face matching info'),
          SignInVoiceIntent.openBiometric);
    });

    test('critical question → critical', () {
      expect(
          parseSignInVoiceIntent(
              'is there anything critical I should be aware of?'),
          SignInVoiceIntent.critical);
      expect(parseSignInVoiceIntent('anything important I need to know?'),
          SignInVoiceIntent.critical);
    });

    test('a bare mention without an open cue does not navigate', () {
      // Casual acceptance / chatter must not pull up a legal screen.
      expect(parseSignInVoiceIntent('yeah I agree to the terms'),
          SignInVoiceIntent.none);
      expect(parseSignInVoiceIntent('sounds good, thanks'),
          SignInVoiceIntent.none);
    });

    test('earliest-mentioned document wins when several are named', () {
      expect(
          parseSignInVoiceIntent('open the terms and then the privacy policy'),
          SignInVoiceIntent.openTerms);
      expect(
          parseSignInVoiceIntent('show me the privacy policy and the terms'),
          SignInVoiceIntent.openPrivacy);
    });

    test('empty / whitespace → none', () {
      expect(parseSignInVoiceIntent(''), SignInVoiceIntent.none);
      expect(parseSignInVoiceIntent('   '), SignInVoiceIntent.none);
    });
  });

  group('kSignInCriticalConsentSummary', () {
    test('covers all four consent items faithfully', () {
      final s = kSignInCriticalConsentSummary.toLowerCase();
      expect(s, contains('18 or older')); // 18+
      expect(s, contains('advertising')); // data-for-advertising
      expect(s, contains('face recognition')); // biometric
      expect(s, contains('public web')); // public-web matching
      expect(s, contains('privacy policy')); // privacy policy governs
    });

    test('exactly four points', () {
      expect(kSignInCriticalConsentPoints.length, 4);
    });
  });
}
