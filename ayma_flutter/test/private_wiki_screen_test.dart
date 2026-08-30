import 'package:ayma_flutter/screens/private_wiki_screen.dart';
import 'package:ayma_flutter/services/wiki_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWikiService extends WikiService {
  _FakeWikiService(this._pages)
      : super(auth: MockFirebaseAuth(signedIn: true));

  final List<WikiPageView> _pages;

  @override
  Future<List<WikiPageView>> readPrivateWiki() async => _pages;
}

void main() {
  testWidgets('renders each page as a titled narrative section', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: PrivateWikiScreen(
        wikiService: _FakeWikiService(const [
          WikiPageView(
            pageId: 'rock-climbing',
            pageType: 'interests',
            body: '## Climbing\nShe climbs every Sunday.\n\nBouldering mostly.',
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Rock climbing'), findsOneWidget); // heading from page_id
    expect(find.textContaining('She climbs every Sunday.'), findsOneWidget);
    expect(find.textContaining('Bouldering mostly.'), findsOneWidget);
    // markdown heading marker stripped
    expect(find.textContaining('##'), findsNothing);
  });

  testWidgets('shows an empty-state message with no pages', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: PrivateWikiScreen(wikiService: _FakeWikiService(const [])),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('your story will start to take shape'),
        findsOneWidget);
  });
}
