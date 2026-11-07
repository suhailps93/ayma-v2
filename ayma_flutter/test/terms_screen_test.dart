import 'package:ayma_flutter/legal/terms_text.dart';
import 'package:ayma_flutter/screens/terms_screen.dart';
import 'package:ayma_flutter/services/legal_links.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'the legacy route opens the hosted Terms directly and renders no '
      'in-between screen', (tester) async {
    final launched = <Uri>[];
    LegalLinks.setLauncherForTesting((url) async {
      launched.add(url);
      return true;
    });
    addTearDown(() => LegalLinks.setLauncherForTesting(null));

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: const TermsScreen(),
    ));
    await tester.pumpAndSettle();

    // Arriving on the route launches the single hosted source at once.
    expect(launched, [Uri.parse('https://ayma-ai.web.app/terms.html')]);
    // No middle screen: no message, no re-open button, no printed address.
    expect(find.byKey(const Key('legal_link_open')), findsNothing);
    expect(find.text('Open Terms of Service'), findsNothing);
    expect(find.textContaining('Opening the Terms of Service'), findsNothing);
    expect(find.text(TermsScreen.url), findsNothing);
    // The full Terms body (and its key-points box) is not rendered either.
    expect(find.byKey(const Key('terms_key_points')), findsNothing);
    expect(find.textContaining('facial analysis and physique'), findsNothing);
  });

  test('points at the canonical hosted Terms URL', () {
    expect(TermsScreen.url, 'https://ayma-ai.web.app/terms.html');
    expect(LegalLinks.termsUrl, 'https://ayma-ai.web.app/terms.html');
  });

  test('key points state the risky clauses plainly and in bold', () {
    final lines = kTermsKeyPoints
        .split('\n- ')
        .skip(1)
        .map((l) => l.trim())
        .toList();
    expect(lines.length, inInclusiveRange(3, 6));
    for (final l in lines) {
      expect(l, startsWith('**'));
      expect(l, endsWith('**'));
    }
    expect(kTermsKeyPoints, contains('18 or older'));
    expect(kTermsKeyPoints, contains('face recognition'));
    expect(kTermsKeyPoints, contains('30-day recovery window'));
    expect(kTermsKeyPoints, contains('use your data for advertising'));
    expect(kTermsKeyPoints, contains('No ads are shown in the current version'));
    expect(kTermsKeyPoints, contains('not end-to-end encrypted'));
  });

  test('kTermsText covers advertising, encryption and AI content', () {
    expect(kTermsText, contains('## Advertising'));
    expect(kTermsText, contains('**No ads are shown in the current version'));
    expect(kTermsText, contains('**The ads may be personalised.**'));
    expect(kTermsText, contains('## Security and encryption'));
    expect(kTermsText, contains('**Ayma is not end-to-end encrypted.**'));
    expect(kTermsText, contains('RevenueCat'));
    expect(kTermsText, contains('Sentry'));
    expect(kTermsText, contains('## AI-generated content'));
    expect(kTermsText, contains('## Content moderation and reporting'));
    expect(kTermsText, contains('## Age: 18 and over only'));
    expect(kTermsText, isNot(contains('Internal note')));
    expect(kTermsText, isNot(contains('third-party advertising')));
  });

  test('kTermsText covers the disclosed points', () {
    expect(kTermsText, contains('facial analysis and physique'));
    expect(kTermsText, contains('publicly available online'));
    expect(kTermsText, contains('only about **you, the account holder**'));
    expect(kTermsText,
        contains('not shown in\nyour visible profile unless you ask'));
  });

  test('kTermsText has no unresolved placeholders', () {
    expect(kTermsText, isNot(contains('PLACEHOLDER')));
    expect(kTermsText, isNot(contains('[PLACEHOLDER — legal review needed]')));
  });

  // Regression (N6): the Terms source must not leak the internal
  // drafting / attorney-review reminders that lived in the source as
  // `> **Note:** …` blockquotes. Each of these phrases was once shipped; none
  // may ever return to the canonical copy (the hosted page is generated from
  // the same `docs/TERMS.md` → `kTermsText`).
  test('kTermsText contains no internal drafting notes', () {
    expect(kTermsText, isNot(contains('**Note:**')));
    expect(kTermsText, isNot(contains('A lawyer must still insert')));
    expect(kTermsText, isNot(contains('A lawyer should confirm')));
    expect(kTermsText, isNot(contains('registered address and governing')));
    expect(kTermsText, isNot(contains('postal address for formal')));
  });

  test('kTermsText covers the previously stubbed sections', () {
    // Safety
    expect(kTermsText, contains('## Safety'));
    expect(kTermsText, contains('We do not verify users'));
    expect(kTermsText, contains('Emergencies are not us'));
    // Your data
    expect(kTermsText, contains('## Your data'));
    expect(kTermsText, contains('We do not sell your personal data today'));
    expect(kTermsText, contains('Google Firebase'));
    expect(kTermsText, contains('LiveKit'));
    expect(kTermsText, contains('30-day recovery window'));
    // Payments and credits
    expect(kTermsText, contains('## Payments and credits'));
    expect(kTermsText, contains('generally non-refundable'));
    expect(kTermsText, contains('Apple App Store or Google Play'));
    // Changes to these Terms
    expect(kTermsText, contains('## Changes to these Terms'));
    expect(kTermsText, contains('that means you accept'));
    // Contact
    expect(kTermsText, contains('## Contact'));
    expect(kTermsText, contains('in-app feedback tool'));
  });

  test('kTermsText is dated today and points at the Privacy Policy', () {
    expect(kTermsText, contains('_Last updated: 2026-10-25_'));
    expect(kTermsText, contains('Privacy Policy'));
  });
}
