import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/taste_match_card.dart';
import 'package:ayma_flutter/widgets/taste_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A match report payload with an embedded "Taste match"
/// [taste] section (`GET /match/{id}` → `taste`).
Map<String, dynamic> _report({Object? taste}) => {
      'match_id': 'me__her',
      'score': 0.82,
      'other': {'uid': 'her', 'name': 'Maya', 'photo': ''},
      'me': {'photo': ''},
      if (taste != null) 'taste': taste,
    };

Map<String, dynamic> _tasteOk() => {
      'status': 'ok',
      'source': 'qloo',
      'score': 68,
      'score_label': 'Good taste overlap',
      'summary': 'You both lean dreamy psych-rock and slow-burn films.',
      'shared': ['Khruangbin', 'Arrival'],
      'domains': [
        {'domain': 'music', 'score': 70},
        {'domain': 'film', 'score': 66},
      ],
      'date_ideas': [
        {
          'name': 'Tartine Manufactory',
          'kind': 'dining',
          'why': 'Ranked for both of your tastes.',
          'address': '595 Alabama St, San Francisco',
        },
      ],
    };

Widget _host(Widget child) => MaterialApp(
      theme: AymaTheme.dark,
      home: Scaffold(body: ListView(children: [child])),
    );

void main() {
  group('MatchReport.fromMap parses the taste section', () {
    test('status "ok" → a populated TasteMatch', () {
      final r = MatchReport.fromMap(_report(taste: _tasteOk()));
      expect(r.taste, isNotNull);
      expect(r.taste!.match, isNotNull);
      expect(r.taste!.note, isNull);
      final m = r.taste!.match!;
      expect(m.score, 68);
      expect(m.isSample, isFalse);
      expect(m.domains.length, 2);
      expect(m.dateIdeas.single.name, 'Tartine Manufactory');
    });

    test('status "no_taste" → an empty-state note', () {
      final r = MatchReport.fromMap(_report(
        taste: {'status': 'no_taste', 'message': 'Maya has no Taste page yet.'},
      ));
      expect(r.taste, isNotNull);
      expect(r.taste!.match, isNull);
      expect(r.taste!.note, 'Maya has no Taste page yet.');
    });

    test('absent taste → no section', () {
      expect(MatchReport.fromMap(_report()).taste, isNull);
    });
  });

  group('TasteMatchCard renders the section in the match report', () {
    testWidgets('the populated taste section', (tester) async {
      final load = TasteMatchLoad.match(TasteMatch.fromMap(_tasteOk()));
      await tester.pumpWidget(_host(TasteMatchCard.resolved(load)));
      await tester.pump();

      expect(find.text('Taste match'), findsOneWidget);
      expect(find.text('powered by Qloo'), findsNothing);
      expect(find.byKey(const Key('tasteMatchScore')), findsOneWidget);
      expect(find.text('Good taste overlap'), findsOneWidget);
      expect(find.text('Khruangbin'), findsOneWidget);
      expect(find.byKey(const Key('tasteMatchIdea')), findsOneWidget);
      expect(find.text('Ranked for both of your tastes.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('per-domain bars render for every domain, in demo order, '
        'with the value matching each score', (tester) async {
      // Input deliberately out of order (dining, music, film) to prove the
      // card reorders to the demo's Music → Film → Food & places.
      final load = TasteMatchLoad.match(TasteMatch.fromMap({
        'source': 'qloo',
        'score': 50,
        'score_label': 'Good overlap',
        'summary': 'A summary.',
        'domains': [
          {'domain': 'dining', 'score': 56},
          {'domain': 'music', 'score': 12},
          {'domain': 'film', 'score': 34},
        ],
      }));
      await tester.pumpWidget(_host(TasteMatchCard.resolved(load)));
      await tester.pump();

      expect(find.byKey(const Key('tasteMatchDomains')), findsOneWidget);
      // Labels, including the dining → "Food & places" mapping.
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('Film'), findsOneWidget);
      expect(find.text('Food & places'), findsOneWidget);
      // Each bar's value text equals its domain score (distinct from the
      // overall score 50, so no collision with the big score).
      expect(find.text('12'), findsOneWidget);
      expect(find.text('34'), findsOneWidget);
      expect(find.text('56'), findsOneWidget);
      // Rendered top-to-bottom in demo order regardless of input order.
      final musicY = tester.getTopLeft(find.text('Music')).dy;
      final filmY = tester.getTopLeft(find.text('Film')).dy;
      final foodY = tester.getTopLeft(find.text('Food & places')).dy;
      expect(musicY, lessThan(filmY));
      expect(filmY, lessThan(foodY));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a non-match (no Taste page / degraded) hides the card',
        (tester) async {
      const hint = 'Maya hasn\'t added a public Taste page yet — add one to '
          'see a taste match.';
      await tester.pumpWidget(
        _host(TasteMatchCard.resolved(const TasteMatchLoad.note(hint))),
      );
      await tester.pump();

      // The card is absent — no header, no note, never an error card
      // (§ founder BUG A). Taste is optional enrichment, so its absence is
      // simply not shown.
      expect(find.byKey(const Key('tasteMatchCard')), findsNothing);
      expect(find.text('powered by Qloo'), findsNothing);
      expect(find.text(hint), findsNothing);
      expect(find.byKey(const Key('tasteMatchScore')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
