import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/features/date_sim/date_sim_screen.dart';
import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/date_sim_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
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

/// A fake backend + Firestore: the POST is held open (like the real run) while
/// the test plays the backend's part by writing the sim's docs, exactly as
/// `date_sim.run_simulation` does.
class _Harness {
  _Harness({this.postStatus = 200, this.postBody = '{}'}) {
    auth = MockFirebaseAuth(signedIn: true);
    fs = FakeFirebaseFirestore();
    api = ApiClient(
      auth: auth,
      httpClient: MockClient((req) async {
        if (req.url.path == '/date-sim/estimate') {
          return _json({
            'credits_by_messages': {for (var n = 2; n <= 20; n++) '$n': n * 10},
          });
        }
        if (req.url.path == '/date-sim') {
          simId =
              (jsonDecode(req.body) as Map<String, dynamic>)['sim_id']
                  as String;
          await release.future;
          return http.Response(
            postBody,
            postStatus,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('no', 404);
      }),
    );
  }

  final int postStatus;
  final String postBody;
  final Completer<void> release = Completer<void>();
  late final MockFirebaseAuth auth;
  late final FakeFirebaseFirestore fs;
  late final ApiClient api;
  String simId = '';

  DocumentReference<Map<String, dynamic>> get sim => fs
      .collection('users')
      .doc(auth.currentUser!.uid)
      .collection('date_sims')
      .doc(simId);

  Future<void> start({String status = 'running'}) => sim.set({
    'status': status,
    'persona': {'name': 'Dana', 'age': 30, 'location': 'Berlin'},
    'banner': 'Simulated — not sent to Dana.',
    'max_messages': 6,
  });

  Future<void> say(int seq, String from, String text) => sim
      .collection('messages')
      .doc('00$seq')
      .set({'seq': seq, 'speaker': from, 'text': text});

  Future<void> finish() => sim.update({
    'status': 'done',
    'verdict': {
      'score': 78,
      'score_label': 'Worth a shot',
      'summary': 'You two kept it light and curious — a promising start.',
    },
  });

  Widget screen() => DateSimScreen(
    uid: 'her',
    name: 'Dana',
    api: api,
    service: DateSimService(auth: auth, firestore: fs),
  );
}

Widget _wrap(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? AymaTheme.dark, home: child);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('setup shows the message-count control and run button', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_Harness().screen()));
    await tester.pump();

    expect(find.byKey(const Key('dateSimRunButton')), findsOneWidget);
    expect(find.byKey(const Key('dateSimCountValue')), findsOneWidget);
    expect(find.byKey(const Key('dateSimSetupNote')), findsOneWidget);
    expect(find.text('6'), findsOneWidget); // sensible default
  });

  testWidgets(
    'setup warns that both agents are billed and it uses many credits',
    (tester) async {
      await tester.pumpWidget(_wrap(_Harness().screen()));
      await tester.pump();

      final warning = find.byKey(const Key('dateSimCreditWarning'));
      expect(warning, findsOneWidget);
      expect(find.textContaining('uses a lot of credits'), findsOneWidget);
      await tester.pump();
      expect(find.textContaining('6 AI messages'), findsOneWidget);
      expect(find.textContaining('roughly 60 credits'), findsOneWidget);
      expect(find.textContaining('agents are billed to you'), findsOneWidget);
      // Visible above the run button.
      expect(
        tester.getTopLeft(warning).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('dateSimRunButton'))).dy,
        ),
      );

      await tester.ensureVisible(
        find.byKey(const Key('dateSimCountIncrement')),
      );
      await tester.tap(find.byKey(const Key('dateSimCountIncrement')));
      await tester.pump();
      expect(find.textContaining('8 AI messages'), findsOneWidget);
      expect(find.textContaining('roughly 80 credits'), findsOneWidget);
    },
  );

  testWidgets('an AI Avatar opt-out (403) shows the server message', (
    tester,
  ) async {
    final h = _Harness(
      postStatus: 403,
      postBody: jsonEncode({
        'detail': {
          'code': 'ai_avatar_opt_out_match',
          'message': 'This person has opted out of AI simulations.',
        },
      }),
    )..release.complete();
    await tester.pumpWidget(_wrap(h.screen()));
    await tester.pump();
    await tester.tap(find.byKey(const Key('dateSimRunButton')));
    await _settle(tester);
    expect(
      find.text('This person has opted out of AI simulations.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dateSimRunButton')), findsOneWidget);
  });

  testWidgets('the message-count stepper increments and decrements', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_Harness().screen()));
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

  testWidgets('the transcript streams in message by message, with a typing '
      'row only while running, then the score and CTA on done', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_wrap(h.screen()));
    await tester.pump();
    await tester.tap(find.byKey(const Key('dateSimRunButton')));
    await _settle(tester);

    // No blocking spinner page: the live view is up straight away.
    expect(find.byKey(const Key('dateSimTranscript')), findsOneWidget);
    expect(find.byKey(const Key('dateSimTyping')), findsOneWidget);
    expect(find.byKey(const Key('dateSimMessageForRealButton')), findsNothing);

    await h.start();
    await h.say(0, 'you', 'hey! your climbing photos are unreal');
    await _settle(tester);
    expect(find.byKey(const Key('dateSimBanner')), findsOneWidget);
    expect(find.textContaining('not sent to Dana'), findsOneWidget);
    expect(find.textContaining('climbing photos are unreal'), findsOneWidget);
    expect(find.textContaining('where do you usually climb'), findsNothing);
    expect(find.textContaining('Dana’s AI is typing'), findsOneWidget);

    await h.say(1, 'them', 'haha thanks — where do you usually climb?');
    await _settle(tester);
    expect(find.textContaining('where do you usually climb'), findsOneWidget);
    expect(find.byKey(const Key('dateSimScore')), findsNothing);

    await h.finish();
    await _settle(tester);
    expect(find.byKey(const Key('dateSimTyping')), findsNothing);
    expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
    expect(find.text('78'), findsOneWidget);
    expect(find.textContaining('Worth a shot'), findsOneWidget);
    expect(find.textContaining('light and curious'), findsOneWidget);
    expect(find.textContaining('Message Dana for real'), findsOneWidget);

    h.release.complete();
    await _settle(tester);
    expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
  });

  testWidgets(
    'a failed run shows an inline error under the partial transcript',
    (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_wrap(h.screen()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('dateSimRunButton')));
      await _settle(tester);

      await h.start();
      await h.say(0, 'you', 'hey there!');
      await h.sim.update({
        'status': 'error',
        'error': {
          'code': 'timeout',
          'message': 'The simulation took too long.',
        },
      });
      await _settle(tester);

      expect(find.textContaining('hey there!'), findsOneWidget);
      expect(find.byKey(const Key('dateSimRunError')), findsOneWidget);
      expect(find.textContaining('took too long'), findsOneWidget);
      expect(find.byKey(const Key('dateSimTyping')), findsNothing);
    },
  );

  testWidgets('out of credits (402) returns to setup', (tester) async {
    final h = _Harness(postStatus: 402)..release.complete();
    await tester.pumpWidget(_wrap(h.screen()));
    await tester.pump();
    await tester.tap(find.byKey(const Key('dateSimRunButton')));
    await _settle(tester);
    expect(find.byKey(const Key('dateSimTranscript')), findsNothing);
    expect(find.byKey(const Key('dateSimRunButton')), findsOneWidget);
  });

  testWidgets('a profile with no simulatable person shows an error', (
    tester,
  ) async {
    final h = _Harness(postStatus: 404)..release.complete();
    await tester.pumpWidget(_wrap(h.screen()));
    await tester.pump();
    await tester.tap(find.byKey(const Key('dateSimRunButton')));
    await _settle(tester);
    expect(find.byKey(const Key('dateSimError')), findsOneWidget);
  });

  testWidgets(
    'a finished run reopens from its sim id and renders in both themes',
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'done');
      await h.say(0, 'you', 'hey there!');
      await h.finish();
      for (final theme in [AymaTheme.light, AymaTheme.dark]) {
        await tester.pumpWidget(
          _wrap(
            DateSimScreen(
              key: ValueKey(theme),
              uid: 'her',
              name: 'Dana',
              api: h.api,
              simId: 'sim1',
              service: DateSimService(auth: h.auth, firestore: h.fs),
            ),
            theme: theme,
          ),
        );
        await _settle(tester);
        expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
      }
    },
  );

  // --- entry point on the profile rail ------------------------------------ //
  testWidgets('profile shows a Simulate-a-date button that opens the sim', (
    tester,
  ) async {
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
              {
                'page_type': 'identity',
                'title': '',
                'body': 'Lives in Berlin.',
              },
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
                    'text': 'Lives in Berlin.',
                  },
                ],
              },
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
