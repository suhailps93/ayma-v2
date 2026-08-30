import 'package:ayma_flutter/screens/public_wiki_screen.dart';
import 'package:ayma_flutter/services/wiki_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWikiService extends WikiService {
  _FakeWikiService(this._public)
      : super(auth: MockFirebaseAuth(signedIn: true));

  final List<WikiPageView> _public;

  @override
  Future<List<WikiPageView>> readPublicWiki() async => _public;
}

void main() {
  testWidgets('renders the public pages as a narrative', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: PublicWikiScreen(
        wikiService: _FakeWikiService(const [
          WikiPageView(
            pageId: 'sailing',
            pageType: 'interests',
            body: 'She sails a small dinghy most weekends.',
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Your public profile'), findsOneWidget);
    expect(find.textContaining('sails a small dinghy'), findsOneWidget);
  });

  testWidgets('empty public profile shows the sharing prompt', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: PublicWikiScreen(wikiService: _FakeWikiService(const [])),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing here is public yet'), findsOneWidget);
  });
}
