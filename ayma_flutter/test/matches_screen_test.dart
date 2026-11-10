import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:ayma_flutter/screens/matches_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/match_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeMatchService extends MatchService {
  _FakeMatchService(this._matches, {Map<String, MatchView>? byId})
      : _byId = byId ?? const {},
        super(auth: MockFirebaseAuth(signedIn: true));

  final List<MatchView> _matches;
  final Map<String, MatchView> _byId;
  final List<(String, bool)> responded = [];
  int failNextResponds = 0;
  bool errorStream = false;

  @override
  Stream<List<MatchView>> watchNewMatches() => errorStream
      ? Stream<List<MatchView>>.error(StateError('boom'))
      : Stream.value(_matches);

  @override
  Future<MatchView> fetchMatch(String matchId) async {
    final m = _byId[matchId];
    if (m == null) throw StateError('No such match: $matchId');
    return m;
  }

  @override
  Future<void> respond(String matchId, {required bool accept}) async {
    if (failNextResponds > 0) {
      failNextResponds--;
      throw StateError('refused');
    }
    responded.add((matchId, accept));
  }
}

const _m = MatchView(
  matchId: 'a__me',
  otherUid: 'a',
  otherName: 'Robin',
  score: 0.82,
  myExplanation: 'You both want a calm home life and value directness.',
  status: 'scored',
);

/// A realistic `/explore/profile/{uid}` response — the same shape the real
/// public profile screen renders (photo, name, age, location, bio pages).
Map<String, dynamic> _profileJson({String name = 'Robin'}) => {
      'uid': 'a',
      'self': false,
      'blocked': false,
      'name': name,
      'age': 29,
      'location': 'Lisbon',
      'photos': <String>[],
      'pages': [
        {'page_type': 'identity', 'title': '', 'body': 'Grew up by the sea.'},
        {'page_type': 'interests', 'title': '', 'body': 'Surfing and design.'},
      ],
      'liked': false,
      'score': 0.82,
      'thread_id': 'a__me',
      'has_chatted': false,
      'physical_attributes': null,
    };

ApiClient _fakeApi({Map<String, dynamic>? profile}) => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/explore/profile/a') {
          return http.Response(jsonEncode(profile ?? _profileJson()), 200);
        }
        if (req.url.path == '/report/public_profile/a') {
          final pages =
              ((profile ?? _profileJson())['pages'] as List).cast<Map>();
          return http.Response(
            jsonEncode({
              'title': 'Robin',
              'sections': [
                for (var i = 0; i < pages.length; i++)
                  {
                    'heading': pages[i]['page_type'],
                    'blocks': [
                      {
                        'block_id': 'sec:$i:sent:0',
                        'type': 'text',
                        'editable': false,
                        'text': pages[i]['body'],
                      },
                    ],
                  },
              ],
              'meta': {
                'owner_uid': 'a',
                'viewer_can_edit': false,
                'created_at': null,
                'updated_at': null,
              },
            }),
            200,
          );
        }
        return http.Response('no', 404);
      }),
    );

void main() {
  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.physicalSize = const Size(1200, 3200);
    b.platformDispatcher.views.first.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.resetPhysicalSize();
    b.platformDispatcher.views.first.resetDevicePixelRatio();
  });

  testWidgets('lists match cards and opens the detail with the full profile',
      (tester) async {
    final svc = _FakeMatchService(const [_m]);
    await tester.pumpWidget(
      MaterialApp(
          home: MatchesScreen(matchService: svc, api: _fakeApi())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Robin'), findsOneWidget);
    expect(find.text('82%'), findsOneWidget);

    await tester.tap(find.text('Robin'));
    // Not pumpAndSettle from here down: the detail screen is now wrapped in
    // `NavBarShell` (§ persistent nav bar, every screen), whose bar carries a
    // perpetually-animating `AymaOrb` — same reason main_shell_screen_test.dart
    // uses bounded pumps around its own orb instead of pumpAndSettle. Two
    // 300ms steps (not one): the push transition (a standard 300ms
    // `MaterialPageRoute` animation) needs to fully finish, or the covered
    // `MatchesScreen` route underneath isn't yet marked offstage and its own
    // still-visible match card (a truncated, 3-line copy of the same
    // explanation text) makes `find.text` below match twice.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // Ayma's score + blurb are still there, as an addition...
    expect(find.text('82% match'), findsOneWidget);
    expect(find.text('You both want a calm home life and value directness.'),
        findsOneWidget);
    expect(find.text('Pass'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    // ...on top of the same full public profile the profile screen shows —
    // name, age, location, bio sections — not the bare "Someone" placeholder.
    expect(find.text('Robin'), findsWidgets); // title bar + header
    expect(find.text('Lisbon'), findsOneWidget);
    expect(find.text('Grew up by the sea.'), findsOneWidget);
    expect(find.text('Surfing and design.'), findsOneWidget);
  });

  testWidgets(
      'reached via a route (a notification tap) with only the matchId '
      'fetches the match and its full profile', (tester) async {
    final svc = _FakeMatchService(const [], byId: {'a__me': _m});
    await tester.pumpWidget(MaterialApp(
      home: MatchDetailScreen(
        matchId: 'a__me',
        service: svc,
        api: _fakeApi(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('82% match'), findsOneWidget);
    expect(find.text('Robin'), findsWidgets);
    expect(find.text('Grew up by the sea.'), findsOneWidget);
  });

  testWidgets('accept posts the response and shows confirmation',
      (tester) async {
    final svc = _FakeMatchService(const [_m]);
    await tester.pumpWidget(
      MaterialApp(
          home: MatchesScreen(matchService: svc, api: _fakeApi())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Robin'));
    // See the note in the test above — the detail screen's `NavBarShell` bar
    // never settles, so bounded pumps from here down instead of pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Accept'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(svc.responded, [('a__me', true)]);
    expect(find.text('Accepted'), findsOneWidget);
  });

  testWidgets('a refused response offers Retry, which posts the same choice',
      (tester) async {
    final svc = _FakeMatchService(const [], byId: {'a__me': _m})
      ..failNextResponds = 1;
    await tester.pumpWidget(MaterialApp(
      home: MatchDetailScreen(
        matchId: 'a__me',
        service: svc,
        api: _fakeApi(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(svc.responded, isEmpty);
    expect(find.textContaining("That didn't work"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(svc.responded, [('a__me', true)]);
    expect(find.text('Accepted'), findsOneWidget);
  });

  testWidgets('empty state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: MatchesScreen(matchService: _FakeMatchService(const []))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No new matches yet'), findsOneWidget);
  });

  // R9 (token follow-up #2): the list-card score label was raw accent (cluster
  // 15 left it for the token owner to route). It is now routed to the extended
  // accentText so it clears the 4.5 text floor on the bgCard card — it is no
  // longer the raw accent. Colour assertions pump without a theme, so
  // `context.ac` is `AymaTokens.dark`.
  testWidgets('list score label is routed to accentText (R9), not raw accent',
      (tester) async {
    final svc = _FakeMatchService(const [_m]);
    await tester.pumpWidget(
      MaterialApp(home: MatchesScreen(matchService: svc, api: _fakeApi())),
    );
    await tester.pumpAndSettle();
    final score = tester.widget<Text>(find.text('82%'));
    expect(score.style?.color, AymaTokens.dark.accentText);
    expect(score.style?.color, isNot(AymaTokens.dark.accent),
        reason: 'R9 recoloured the raw accent to the card-safe accentText');
  });

  // Defect 25: the error text uses `errorText`, not raw error.
  testWidgets('error text uses the errorText token (defect 25)',
      (tester) async {
    final svc = _FakeMatchService(const [])..errorStream = true;
    await tester.pumpWidget(
      MaterialApp(home: MatchesScreen(matchService: svc, api: _fakeApi())),
    );
    await tester.pumpAndSettle();
    final err =
        tester.widget<Text>(find.textContaining('Could not load matches'));
    expect(err.style?.color, AymaTokens.dark.errorText);
  });

  testWidgets("the match-request header card (score + a long explanation) lays out without overflow at a small screen, above the profile", (WidgetTester tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(320, 568);
    addTearDown(() => binding.platformDispatcher.views.first.resetPhysicalSize());

    const longExplain = 'Since you both want a calm home life and value directness, and share a love of the outdoors, late films and slow mornings — this looks like a genuinely strong fit across the dimensions that matter most to each of you. ';
    final m = MatchView(
      matchId: 'a__me',
      otherUid: 'a',
      otherName: 'Robin',
      score: 0.0,
      myExplanation: longExplain,
      status: 'scored',
    );
    final svc = _FakeMatchService(const [], byId: {'a__me': m});

    await tester.pumpWidget(MaterialApp(home: MatchDetailScreen(matchId: 'a__me', service: svc, api: _fakeApi())));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('0% match'), findsOneWidget);
    expect(find.textContaining('Since you both want a calm home life'), findsWidgets);
    expect(find.text('Robin'), findsWidgets);
  });

  // R9 (folds into R6) — both match-score labels sit on a bgCard card and now
  // route through the extended accentText so they clear the 4.5 text floor on
  // bgCard. The AymaTokens extension is injected directly (the full AymaTheme's
  // serif textTheme would try to fetch a web font in tests).
  for (final theme in <(String, AymaTokens)>[
    ('light', AymaTokens.light),
    ('dark', AymaTokens.dark),
  ]) {
    final (name, tokens) = theme;

    testWidgets('R9: list match-score (mono 12) uses accentText and reads on '
        'bgCard ($name)', (tester) async {
      final svc = _FakeMatchService(const [_m]);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(extensions: [tokens]),
        home: MatchesScreen(matchService: svc, api: _fakeApi()),
      ));
      await tester.pumpAndSettle();
      final score = tester.widget<Text>(find.text('82%'));
      expect(score.style?.color, tokens.accentText,
          reason: 'list score routes through accentText');
      expect(_contrastRatio(score.style!.color!, tokens.bgCard),
          greaterThanOrEqualTo(4.5),
          reason: 'list score reads on the bgCard card');
    });

    testWidgets('R9: detail match-score (mono 14) uses accentText and reads on '
        'bgCard ($name)', (tester) async {
      final svc = _FakeMatchService(const [], byId: {'a__me': _m});
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(extensions: [tokens]),
        home: MatchDetailScreen(matchId: 'a__me', service: svc, api: _fakeApi()),
      ));
      await tester.pumpAndSettle();
      final score = tester.widget<Text>(find.text('82% match'));
      expect(score.style?.color, tokens.accentText,
          reason: 'detail score routes through accentText');
      expect(_contrastRatio(score.style!.color!, tokens.bgCard),
          greaterThanOrEqualTo(4.5),
          reason: 'detail score reads on the bgCard card');
    });

    // R6 — a dialog TextButton label routes through the theme's accentText
    // foreground (as the app's textButtonTheme wires it) and, after R6, reads
    // on the dialog's bgCard-level surface. This proves the theme-level fix
    // covers dialog actions (consent / web-search dialogs) with no call-site
    // change.
    testWidgets('R6: dialog TextButton label uses accentText and reads on the '
        'bgCard dialog surface ($name)', (tester) async {
      final theme = ThemeData(
        extensions: [tokens],
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: tokens.accentText),
        ),
      );
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          backgroundColor: tokens.bgCard,
          body: Center(
            child: TextButton(onPressed: () {}, child: const Text('Continue')),
          ),
        ),
      ));
      await tester.pump();
      // The rendered label color resolves to accentText via the button theme.
      RichText? label;
      for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
        if ((rt.text as TextSpan).toPlainText() == 'Continue') label = rt;
      }
      expect(label, isNotNull);
      final color = (label!.text as TextSpan).style?.color;
      expect(color, tokens.accentText,
          reason: 'dialog TextButton label is accentText');
      expect(_contrastRatio(color!, tokens.bgCard), greaterThanOrEqualTo(4.5),
          reason: 'dialog action label reads on bgCard (R6)');
    });
  }
}

/// WCAG contrast ratio for the widget assertions above (mirrors the pure-ratio
/// helper in color_audit_test.dart).
double _contrastRatio(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}
