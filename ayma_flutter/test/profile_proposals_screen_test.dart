// ProfileProposalsScreen (Ayma's pending public-profile updates). These tests
// pin the Jobs-pass spacing/colour fixes (cluster 8, fleet/jobs-profile-own):
//   - the list and the error/empty states share one 20 screen edge;
//   - every TextButton clears the 44 absolute-minimum touch floor;
//   - removed-change rows read as muted (fgDim/onSurfaceVariant) + strikethrough
//     instead of the raw error red that failed the 4.5 text floor on the card;
//   - the inline error line uses the card/bg-safe `errorText` token.
import 'dart:convert';

import 'package:ayma_flutter/screens/profile_proposals_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/overflow_guards.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One section with a removed and an added change, so the row-colour and
/// per-row button assertions have real rows to read.
String _proposalsJson() => jsonEncode({
      'proposals': [
        {
          'page_id': 'identity',
          'title': 'Identity',
          'changes': [
            {'id': 'c1', 'op': 'remove', 'text': 'Old removed sentence'},
            {'id': 'c2', 'op': 'add', 'text': 'New added sentence'},
          ],
        },
      ],
    });

ApiClient _api(MockClient http) =>
    ApiClient(httpClient: http, auth: MockFirebaseAuth(signedIn: true));

Widget _host(ApiClient api) => MaterialApp(
      theme: AymaTheme.dark,
      home: ProfileProposalsScreen(apiClient: api),
    );

void main() {
  testWidgets('list screen edge is the 20 standard', (tester) async {
    final api = _api(MockClient((req) async => http.Response(
          _proposalsJson(),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        )));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.padding, const EdgeInsets.all(20));
  });

  testWidgets('empty state shares the 20 edge', (tester) async {
    final api = _api(MockClient((req) async => http.Response(
          jsonEncode({'proposals': []}),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        )));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    expect(find.text('No suggestions right now'), findsOneWidget);
    final scroll = tester.widget<CenteredScroll>(find.byType(CenteredScroll));
    expect(scroll.padding, const EdgeInsets.all(20));
  });

  testWidgets('load-failed state shares the 20 edge and its Retry is >= 44',
      (tester) async {
    final api = _api(MockClient((req) async => http.Response('nope', 500)));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load the suggestions."), findsOneWidget);
    final scroll = tester.widget<CenteredScroll>(find.byType(CenteredScroll));
    expect(scroll.padding, const EdgeInsets.all(20));

    // Local Size(0,44) override removed (T3); the theme minimum now renders
    // Retry at 48 (padded tap target), clearing the 44 floor.
    expect(
        tester.getSize(find.widgetWithText(TextButton, 'Retry')).height, 48);
  });

  testWidgets('every TextButton clears the 44 touch floor', (tester) async {
    final api = _api(MockClient((req) async => http.Response(
          _proposalsJson(),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        )));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    // Per-row Dismiss (one per change), section Dismiss all + Apply all (the
    // section has >1 change, so the "all" bar renders). Every one must be >=44.
    // Local Size(0,44) overrides removed (T3): every TextButton renders 48 via
    // the theme minimum + M3 padded tap target.
    for (final label in const ['Dismiss', 'Dismiss all', 'Apply all']) {
      final finder = find.widgetWithText(TextButton, label);
      expect(finder, findsWidgets, reason: 'expected a "$label" TextButton');
      for (var i = 0; i < finder.evaluate().length; i++) {
        expect(tester.getSize(finder.at(i)).height, 48,
            reason: '$label must render 48 tall');
      }
    }
    // The sibling per-row Apply FilledButtons keep their load-bearing local
    // Size(0,44) (the FilledButton theme is infinite-width inside the Wrap —
    // see profile_proposals_screen, build 2208) and also render 48.
    final applyFinder = find.widgetWithText(FilledButton, 'Apply');
    for (var i = 0; i < applyFinder.evaluate().length; i++) {
      expect(tester.getSize(applyFinder.at(i)).height, 48);
    }
  });

  testWidgets('removed row is muted + strikethrough, not raw error red',
      (tester) async {
    final api = _api(MockClient((req) async => http.Response(
          _proposalsJson(),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        )));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    final removed =
        tester.widget<Text>(find.text('- Old removed sentence'));
    final scheme = AymaTheme.dark.colorScheme;
    expect(removed.style!.color, scheme.onSurfaceVariant);
    expect(removed.style!.color, isNot(scheme.error));
    expect(removed.style!.decoration, TextDecoration.lineThrough);
  });

  testWidgets('inline error line uses the card/bg-safe errorText token',
      (tester) async {
    var applyCalls = 0;
    final api = _api(MockClient((req) async {
      if (req.method == 'POST') {
        applyCalls++;
        return http.Response('fail', 500);
      }
      return http.Response(
        _proposalsJson(),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }));
    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Apply').first);
    await tester.pumpAndSettle();

    expect(applyCalls, greaterThan(0));
    final errorText = tester
        .widget<Text>(find.textContaining("Couldn't apply that change"));
    expect(errorText.style!.color, AymaTokens.dark.errorText);
  });
}
