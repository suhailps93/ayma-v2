import 'package:ayma_flutter/screens/private_wiki_screen.dart';
import 'package:ayma_flutter/services/wiki_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWikiService extends WikiService {
  _FakeWikiService(this._pages)
      : super(auth: MockFirebaseAuth(signedIn: true));

  List<WikiPageView> _pages;
  final List<String> calls = [];

  @override
  Future<List<WikiPageView>> readPrivateWiki() async => _pages;

  @override
  Future<void> setUserEdit(String pageId, String text) async {
    calls.add('edit:$pageId:$text');
    _pages = [
      for (final p in _pages)
        if (p.pageId == pageId)
          WikiPageView(pageId: p.pageId, pageType: p.pageType, body: text)
        else
          p,
    ];
  }

  @override
  Future<void> hidePage(String pageId) async {
    calls.add('hide:$pageId');
    _pages = [for (final p in _pages) if (p.pageId != pageId) p];
  }

  @override
  Future<void> resetPage(String pageId) async => calls.add('reset:$pageId');
}

Future<void> _pump(WidgetTester tester, _FakeWikiService svc) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: PrivateWikiScreen(wikiService: svc)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders each page as a titled narrative section', (tester) async {
    await _pump(
      tester,
      _FakeWikiService(const [
        WikiPageView(
          pageId: 'rock-climbing',
          pageType: 'interests',
          body: '## Climbing\nShe climbs every Sunday.\n\nBouldering mostly.',
        ),
      ]),
    );

    expect(find.text('Rock climbing'), findsOneWidget);
    expect(find.textContaining('She climbs every Sunday.'), findsOneWidget);
    expect(find.textContaining('##'), findsNothing);
  });

  testWidgets('shows an empty-state message with no pages', (tester) async {
    await _pump(tester, _FakeWikiService(const []));
    expect(find.textContaining('your story will start to take shape'),
        findsOneWidget);
  });

  testWidgets('editing a section writes user_edits and re-renders', (tester) async {
    final svc = _FakeWikiService(const [
      WikiPageView(
        pageId: 'career',
        pageType: 'career',
        body: 'Ayma thinks she is a junior analyst.',
      ),
    ]);
    await _pump(tester, svc);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField), 'Actually I lead the analytics team now.');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(svc.calls,
        ['edit:career:Actually I lead the analytics team now.']);
    expect(find.textContaining('lead the analytics team'), findsOneWidget);
  });

  testWidgets('hiding a section removes it from the view', (tester) async {
    final svc = _FakeWikiService(const [
      WikiPageView(pageId: 'ex', pageType: 'relationships', body: 'About an ex.'),
    ]);
    await _pump(tester, svc);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide this from my profile'));
    await tester.pumpAndSettle();

    expect(svc.calls, ['hide:ex']);
    expect(find.textContaining('About an ex.'), findsNothing);
  });
}
