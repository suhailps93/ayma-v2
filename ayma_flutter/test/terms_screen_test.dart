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
}
