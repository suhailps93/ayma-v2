import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/taste_match_card.dart';
import 'package:ayma_flutter/widgets/taste_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A match report payload with an embedded "Taste match · powered by Qloo"
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
          'why': 'Ranked by Qloo for both of your tastes.',
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
      expect(find.text('powered by Qloo'), findsOneWidget);
      expect(find.byKey(const Key('tasteMatchScore')), findsOneWidget);
      expect(find.text('Good taste overlap'), findsOneWidget);
      expect(find.text('Khruangbin'), findsOneWidget);
      expect(find.byKey(const Key('tasteMatchIdea')), findsOneWidget);
      expect(find.text('Ranked by Qloo for both of your tastes.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the no-Taste-page empty state', (tester) async {
      const hint = 'Maya hasn\'t added a public Taste page yet — add one to '
          'see a taste match.';
      await tester.pumpWidget(
        _host(TasteMatchCard.resolved(const TasteMatchLoad.note(hint))),
      );
      await tester.pump();

      expect(find.text('powered by Qloo'), findsOneWidget);
      expect(find.byKey(const Key('tasteMatchNote')), findsOneWidget);
      expect(find.text(hint), findsOneWidget);
      expect(find.byKey(const Key('tasteMatchScore')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
