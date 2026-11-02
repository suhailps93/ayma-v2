import 'dart:convert';

import 'package:ayma_flutter/features/date_sim/date_sim_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/date_sim_service.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _taste({String source = 'qloo'}) => {
      'source': source,
      'a': {'name': 'Sam'},
      'b': {'name': 'Maya'},
      'score': 72,
      'score_label': 'Strong overlap',
      'summary': 'You both love dreamy psych-rock and slow-burn films.',
      'shared': ['Khruangbin', 'Lost in Translation'],
      'domains': [
        {'domain': 'music', 'score': 72},
        {'domain': 'film', 'score': 60},
      ],
      'date_ideas': [
        {
          'name': 'Tartine Manufactory',
          'kind': 'dining',
          'why': 'You both rate cosy bakeries.',
          'address': null,
        },
      ],
    };

/// The date-sim backend, with `/taste/pair` answering [taste].
ApiClient _api(http.Response Function() taste) => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        switch (req.url.path) {
          case '/date-sim/estimate':
            return _json({'credits_by_messages': {'6': 60}});
          case '/taste/pair':
            expect(jsonDecode(req.body), {'other_uid': 'her'});
            return taste();
        }
        return http.Response('no', 404);
      }),
    );

/// A finished simulation, already streamed into Firestore, reopened by id.
///
/// [expectCard] scrolls the taste card into view before returning; pass false
/// when the taste match is absent (no Taste page / failure) so there's nothing
/// to scroll to.
Future<void> _runSim(
  WidgetTester tester,
  ApiClient api, {
  bool expectCard = true,
}) async {
  final auth = MockFirebaseAuth(signedIn: true);
  final fs = FakeFirebaseFirestore();
  final sim = fs
      .collection('users')
      .doc(auth.currentUser!.uid)
      .collection('date_sims')
      .doc('sim1');
  await sim.set({
    'status': 'done',
    'persona': {'name': 'Maya'},
    'banner': 'Simulated — not sent to Maya.',
    'verdict': {
      'score': 70,
      'score_label': 'Worth a shot',
      'summary': 'A promising start.',
    },
  });
  await sim
      .collection('messages')
      .doc('000')
      .set({'seq': 0, 'speaker': 'you', 'text': 'hey!'});
  await sim
      .collection('messages')
      .doc('001')
      .set({'seq': 1, 'speaker': 'them', 'text': 'hi there'});
  await tester.pumpWidget(MaterialApp(
    theme: AymaTheme.dark,
    home: DateSimScreen(
      uid: 'her',
      name: 'Maya',
      api: api,
      simId: 'sim1',
      service: DateSimService(auth: auth, firestore: fs),
      profiles: ProfileService(auth: auth, firestore: fs),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  if (expectCard) {
    await tester.scrollUntilVisible(
      find.byKey(const Key('tasteMatchCard')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('dateSimTranscript')),
        matching: find.byType(Scrollable),
      ),
    );
  }
  await tester.pump();
}

void main() {
  testWidgets('renders the taste match under the compatibility read',
      (tester) async {
    await _runSim(tester, _api(() => _json(_taste())));

    // `_runSim` has scrolled the taste card into view; assert its contents
    // here (the taller bars push the verdict score above the built range).
    expect(find.text('Taste match'), findsOneWidget);
    expect(find.text('powered by Qloo'), findsOneWidget);
    expect(find.byKey(const Key('tasteMatchScore')), findsOneWidget);
    expect(find.text('Strong overlap'), findsOneWidget);
    // Per-domain bars: labelled rows with the numeric score at the right.
    // (The Film value 60 is distinct from the overall score 72; a dedicated
    // multi-domain bar test in taste_match_report_section_test.dart asserts
    // every bar value matches its domain score.)
    expect(find.byKey(const Key('tasteMatchDomains')), findsOneWidget);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Film'), findsOneWidget);
    expect(find.text('60'), findsOneWidget);
    expect(find.text('Khruangbin'), findsOneWidget);
    expect(find.text('Lost in Translation'), findsOneWidget);
    expect(find.text("Date ideas you'd both enjoy"), findsOneWidget);
    expect(find.byKey(const Key('tasteMatchIdea')), findsOneWidget);
    expect(find.text('You both rate cosy bakeries.'), findsOneWidget);
    expect(find.byKey(const Key('tasteMatchSampleChip')), findsNothing);
    expect(tester.takeException(), isNull);

    // Scroll back to the top: the date-sim verdict itself still renders.
    await tester.scrollUntilVisible(
      find.byKey(const Key('dateSimScore')),
      -200,
      scrollable: find.descendant(
        of: find.byKey(const Key('dateSimTranscript')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
  });

  testWidgets('shared_tags chips and demographics note both render',
      (tester) async {
    final taste = {
      ..._taste(),
      'shared_tags': ['Atmospheric', 'Melancholic', 'Psychological drama'],
      'demographics': {
        'a': {'top_age': '24 & under'},
        'b': {'top_age': '45–54'},
        'note': "Maya's tastes index 24 & under, Leo's 45–54.",
      },
    };
    await _runSim(tester, _api(() => _json(taste)));

    expect(find.byKey(const Key('tasteMatchSharedTags')), findsOneWidget);
    expect(find.text('Why you match'), findsOneWidget);
    expect(find.text('Atmospheric'), findsOneWidget);
    expect(find.text('Psychological drama'), findsOneWidget);
    expect(find.byKey(const Key('tasteMatchDemographics')), findsOneWidget);
    expect(find.text("Maya's tastes index 24 & under, Leo's 45–54."),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('absent shared_tags/demographics render neither row',
      (tester) async {
    // The base payload omits both fields entirely.
    await _runSim(tester, _api(() => _json(_taste())));

    expect(find.byKey(const Key('tasteMatchSharedTags')), findsNothing);
    expect(find.text('Why you match'), findsNothing);
    expect(find.byKey(const Key('tasteMatchDemographics')), findsNothing);
    // The rest of the card is unaffected and nothing overflows.
    expect(find.byKey(const Key('tasteMatchScore')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty shared_tags and null-note demographics render neither',
      (tester) async {
    final taste = {
      ..._taste(),
      'shared_tags': <String>[],
      'demographics': {
        'a': {'top_age': '24 & under'},
        'b': {'top_age': '45–54'},
        'note': '',
      },
    };
    await _runSim(tester, _api(() => _json(taste)));

    expect(find.byKey(const Key('tasteMatchSharedTags')), findsNothing);
    expect(find.text('Why you match'), findsNothing);
    expect(find.byKey(const Key('tasteMatchDemographics')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixture data shows the "sample data" chip', (tester) async {
    await _runSim(tester, _api(() => _json(_taste(source: 'fixture'))));

    expect(find.byKey(const Key('tasteMatchSampleChip')), findsOneWidget);
    expect(find.text('sample data'), findsOneWidget);
  });

  testWidgets('no Taste page (404 no_taste) hides the card entirely',
      (tester) async {
    const hint = 'Add a public "Taste" page with lines like "Music: ..." '
        'to see your taste match.';
    await _runSim(
      tester,
      _api(() => _json({
            'detail': {'code': 'no_taste', 'message': hint},
          }, 404)),
      expectCard: false,
    );

    // The card is absent — never a bare note / error. Taste is an optional
    // enrichment; its absence isn't surfaced to the user.
    expect(find.byKey(const Key('tasteMatchCard')), findsNothing);
    expect(find.text(hint), findsNothing);
    expect(find.text('Taste match'), findsNothing);
    expect(find.byKey(const Key('tasteMatchScore')), findsNothing);
    // The date-sim result itself is unaffected.
    expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'any other failure hides the card, never an "unavailable" error card',
      (tester) async {
    // § founder BUG A: a non-200 (or degraded Qloo) used to render a "Taste
    // match unavailable right now." error card. It must now be absent.
    await _runSim(
      tester,
      _api(() => http.Response('boom', 500)),
      expectCard: false,
    );

    expect(find.byKey(const Key('tasteMatchCard')), findsNothing);
    expect(find.text('Taste match unavailable right now.'), findsNothing);
    expect(find.text('Taste match'), findsNothing);
    // The rest of the date-sim result is intact and usable.
    expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
    expect(find.byKey(const Key('dateSimMessageForRealButton')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
