import 'dart:convert';

import 'package:ayma_flutter/features/date_sim/date_sim_screen.dart';
import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _result({
  List<Map<String, dynamic>>? transcript,
  bool usageCapped = false,
}) =>
    {
      'simulation': true,
      'persona': {'name': 'Dana', 'age': 30, 'location': 'Berlin'},
      'banner': 'Simulated — not sent to Dana.',
      'transcript': transcript ??
          const [
            {'from': 'you', 'text': 'hey! your climbing photos are unreal'},
            {'from': 'them', 'text': 'haha thanks — where do you usually climb?'},
          ],
      'score': 78,
      'score_label': 'Worth a shot',
      'summary': 'You two kept it light and curious — a promising start.',
      'moderation': {'flagged': false, 'categories': <String>[]},
      'usage_capped': usageCapped,
    };

ApiClient _api({Object? body, int status = 200}) => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/date-sim') {
          if (status != 200) return http.Response('no', status);
          return _json(body ?? _result());
        }
        return http.Response('no', 404);
      }),
    );

Widget _wrap(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme ?? AymaTheme.dark,
      home: child,
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('setup shows the message-count control and run button',
      (tester) async {
    await tester.pumpWidget(_wrap(DateSimScreen(uid: 'her', name: 'Dana', api: _api())));
    await tester.pump();

    expect(find.byKey(const Key('dateSimRunButton')), findsOneWidget);
    expect(find.byKey(const Key('dateSimCountValue')), findsOneWidget);
    expect(find.byKey(const Key('dateSimSetupNote')), findsOneWidget);
    expect(find.text('6'), findsOneWidget); // sensible default
  });

  testWidgets('the message-count stepper increments and decrements',
      (tester) async {
    await tester.pumpWidget(_wrap(DateSimScreen(uid: 'her', name: 'Dana', api: _api())));
    await tester.pump();

    await tester.tap(find.byKey(const Key('dateSimCountIncrement')));
    await tester.pump();
    expect(find.text('8'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dateSimCountDecrement')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('dateSimCountDecrement')));
    await tester.pump();
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('running shows a simulated-labelled transcript, score, summary '
      'and a Message-for-real CTA', (tester) async {
    await tester.pumpWidget(_wrap(DateSimScreen(uid: 'her', name: 'Dana', api: _api())));
    await tester.pump();

    await tester.tap(find.byKey(const Key('dateSimRunButton')));
    await _settle(tester);

    // Clearly labelled simulation, not sent to the person.
    expect(find.byKey(const Key('dateSimBanner')), findsOneWidget);
    expect(find.textContaining('not sent to Dana'), findsOneWidget);

    // The transcript renders both personas' messages.
    expect(find.byKey(const Key('dateSimTranscript')), findsOneWidget);
    expect(find.textContaining('climbing photos are unreal'), findsOneWidget);
    expect(find.textContaining('where do you usually climb'), findsOneWidget);

    // The compatibility read: a bounded score + a summary.
    expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
    expect(find.text('78'), findsOneWidget);
    expect(find.textContaining('Worth a shot'), findsOneWidget);
    expect(find.byKey(const Key('dateSimSummary')), findsOneWidget);
    expect(find.textContaining('light and curious'), findsOneWidget);

    // The CTA to leave the simulation and message for real.
    expect(find.byKey(const Key('dateSimMessageForRealButton')), findsOneWidget);
    expect(find.textContaining('Message Dana for real'), findsOneWidget);
  });

  testWidgets('a mid-run credit cap still renders the partial transcript',
      (tester) async {
    await tester.pumpWidget(_wrap(DateSimScreen(
      uid: 'her',
      name: 'Dana',
      api: _api(
        body: _result(
          transcript: const [
            {'from': 'you', 'text': 'hey there!'}
          ],
          usageCapped: true,
        ),
      ),
    )));
    await tester.pump();
    await tester.tap(find.byKey(const Key('dateSimRunButton')));
    await _settle(tester);

    expect(find.byKey(const Key('dateSimTranscript')), findsOneWidget);
    expect(find.textContaining('hey there!'), findsOneWidget);
  });

  testWidgets('a profile with no simulatable person shows an error',
      (tester) async {
    await tester.pumpWidget(
        _wrap(DateSimScreen(uid: 'her', name: 'Dana', api: _api(status: 404))));
    await tester.pump();
    await tester.tap(find.byKey(const Key('dateSimRunButton')));
    await _settle(tester);
    expect(find.byKey(const Key('dateSimError')), findsOneWidget);
  });

  testWidgets('both themes render the result', (tester) async {
    for (final theme in [AymaTheme.light, AymaTheme.dark]) {
      await tester.pumpWidget(
          _wrap(
        DateSimScreen(
            key: ValueKey(theme), uid: 'her', name: 'Dana', api: _api()),
        theme: theme,
      ));
      await tester.pump();
      await tester.tap(find.byKey(const Key('dateSimRunButton')));
      await _settle(tester);
      expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
    }
  });

  // --- entry point on the profile rail ------------------------------------ //
  testWidgets('profile shows a Simulate-a-date button that opens the sim',
      (tester) async {
    final pushed = <String>[];
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/explore/profile/her') {
          return _json({
            'uid': 'her',
            'self': false,
            'blocked': false,
            'name': 'Dana',
            'age': 30,
            'location': 'Berlin',
            'photos': <String>[],
            'pages': const [
              {'page_type': 'identity', 'title': '', 'body': 'Lives in Berlin.'},
            ],
            'liked': false,
            'score': null,
            'thread_id': 'her__me',
            'has_chatted': false,
            'deep_dive_id': '',
          });
        }
        if (req.url.path == '/report/public_profile/her' ||
            req.url.path == '/report/story_public/her') {
          return _json({
            'title': 'Dana',
            'sections': const [
              {
                'heading': 'Identity',
                'blocks': [
                  {
                    'block_id': 'sec:0:sent:0',
                    'type': 'text',
                    'editable': false,
                    'text': 'Lives in Berlin.'
                  }
                ]
              }
            ],
            'meta': {
              'owner_uid': 'her',
              'viewer_can_edit': false,
              'created_at': null,
              'updated_at': null,
            },
          });
        }
        return http.Response('no', 404);
      }),
    );
    final router = GoRouter(
      initialLocation: '/profile/user/her',
      routes: [
        GoRoute(
          path: '/profile/user/:uid',
          builder: (_, s) =>
              PublicProfileScreen(uid: s.pathParameters['uid']!, api: api),
        ),
        GoRoute(
          path: '/date-sim/:uid',
          builder: (_, s) {
            pushed.add('/date-sim/${s.pathParameters['uid']}');
            return const Scaffold(body: Text('DATE SIM'));
          },
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await _settle(tester);

    final btn = find.byKey(const Key('profileDateSimButton'));
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await _settle(tester);
    expect(pushed, contains('/date-sim/her'));
    expect(find.text('DATE SIM'), findsOneWidget);
  });
}
