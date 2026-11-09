import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/features/date_sim/date_sim_models.dart';
import 'package:ayma_flutter/features/date_sim/date_sim_screen.dart';
import 'package:ayma_flutter/routing/app_router.dart' show navigateToRoute;
import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/date_sim_service.dart';
import 'package:ayma_flutter/services/notification_service.dart'
    show deepLinkToRoute;
import 'package:ayma_flutter/services/profile_service.dart';
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
  _Harness({
    this.postStatus = 200,
    this.postBody = '{}',
    this.readiness,
    this.continueStatus = 200,
    this.stopBody = const {'status': 'stopping'},
    this.stopStatus = 200,
  }) {
    auth = MockFirebaseAuth(signedIn: true);
    fs = FakeFirebaseFirestore();
    api = ApiClient(
      auth: auth,
      httpClient: MockClient((req) async {
        if (req.url.path == '/date-sim/estimate') {
          return _json({
            'credits_by_messages': {for (var n = 2; n <= 20; n++) '$n': n * 10},
            if (readiness != null) 'readiness': readiness,
          });
        }
        if (req.url.path.endsWith('/continue')) {
          continueCalls.add(req.url.path);
          continueCounts.add(
            (jsonDecode(req.body) as Map<String, dynamic>)['more_messages']
                as int,
          );
          return http.Response(
            '{"status":"done"}',
            continueStatus,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (req.url.path.endsWith('/stop')) {
          stopCalls.add(req.url.path);
          return _json(stopBody, stopStatus);
        }
        if (req.method == 'DELETE' && req.url.path.startsWith('/date-sim/pair/')) {
          resetCalls.add(req.url.path);
          return _json({'deleted': 1});
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

  /// Optional `readiness` block the `/date-sim/estimate` mock returns.
  final Map<String, dynamic>? readiness;

  /// Status for `POST /date-sim/{id}/continue`, and the paths it was called
  /// with (so a test can assert the SAME sim was continued).
  final int continueStatus;

  /// Body + status for `POST /date-sim/{id}/stop`: the server's outcome
  /// (`stopping` for a live run, `already_finished` when the run had already
  /// ended) or an HTTP failure.
  final Map<String, dynamic> stopBody;
  final int stopStatus;
  final List<String> continueCalls = <String>[];

  /// The `more_messages` each `/continue` was called with, so a test can assert
  /// the USER-CHOSEN count flowed through (C).
  final List<int> continueCounts = <int>[];

  /// Call log for `POST /date-sim/{id}/stop` (D).
  final List<String> stopCalls = <String>[];

  /// Call log for `DELETE /date-sim/pair/{otherUid}` (E).
  final List<String> resetCalls = <String>[];
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
    profiles: ProfileService(auth: auth, firestore: fs),
  );

  /// The screen REOPENED on an existing [simId] (watches it; no new run).
  Widget screen2(String simId) => DateSimScreen(
    uid: 'her',
    name: 'Dana',
    api: api,
    simId: simId,
    service: DateSimService(auth: auth, firestore: fs),
    profiles: ProfileService(auth: auth, firestore: fs),
  );
}

Widget _wrap(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? AymaTheme.dark, home: child);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// The date-sim + profile routes as the production router builds them: the
/// sim id rides the `sim_id` query param into [DateSimScreen], and a
/// notification open carries `from=notification` into
/// [DateSimScreen.openedFromNotification].
List<RouteBase> _simRoutes(_Harness h) => [
  GoRoute(
    path: '/profile/user/:uid',
    builder: (_, s) =>
        Scaffold(body: Text('PROFILE ${s.pathParameters['uid']}')),
  ),
  GoRoute(
    path: '/date-sim/:uid',
    builder: (_, s) => DateSimScreen(
      uid: s.pathParameters['uid']!,
      api: h.api,
      simId: s.uri.queryParameters['sim_id'],
      openedFromNotification:
          s.uri.queryParameters['from'] == 'notification',
      service: DateSimService(auth: h.auth, firestore: h.fs),
      profiles: ProfileService(auth: h.auth, firestore: h.fs),
    ),
  ),
];

/// A [DateSimService] whose streams the test drives by hand, so "still
/// loading" (no emission yet) and "confirmed absent" (null emission) are two
/// distinct, deterministic states.
class _GatedSims extends DateSimService {
  _GatedSims({required super.auth, required super.firestore});

  final simController = StreamController<DateSimDoc?>.broadcast();
  final msgController = StreamController<List<DateSimMessage>>.broadcast();

  @override
  Stream<DateSimDoc?> watchSim(String simId) => simController.stream;

  @override
  Stream<List<DateSimMessage>> watchMessages(String simId) =>
      msgController.stream;
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
    'AI Avatar off: shows the in-place enable gate, not the run controls; '
    'turning it on clears the gate',
    (tester) async {
      final h = _Harness();
      final uid = h.auth.currentUser!.uid;
      await h.fs.doc('users/$uid/profile/main').set({'ai_avatar_enabled': false});
      await tester.pumpWidget(_wrap(h.screen()));
      await _settle(tester);

      // Gate up, run controls gone.
      expect(find.byKey(const Key('dateSimAvatarGate')), findsOneWidget);
      expect(find.byKey(const Key('dateSimEnableAvatarButton')), findsOneWidget);
      expect(find.byKey(const Key('dateSimRunButton')), findsNothing);

      await tester.tap(find.byKey(const Key('dateSimEnableAvatarButton')));
      await _settle(tester);

      // The write landed and the stream flipped the gate: controls return.
      final doc = await h.fs.doc('users/$uid/profile/main').get();
      expect(doc.data()?['ai_avatar_enabled'], isTrue);
      expect(find.byKey(const Key('dateSimAvatarGate')), findsNothing);
      expect(find.byKey(const Key('dateSimRunButton')), findsOneWidget);
    },
  );

  testWidgets(
    'low-context match: warns before simulating, without blocking the run',
    (tester) async {
      final h = _Harness(readiness: {
        'name': 'Dana',
        'readiness_score': 12,
        'low_context': true,
      });
      await tester.pumpWidget(_wrap(h.screen()));
      await _settle(tester);

      expect(find.byKey(const Key('dateSimLowContextWarning')), findsOneWidget);
      expect(find.textContaining("doesn't have much context yet"),
          findsOneWidget);
      // Informs, does not block — the run button is still there.
      expect(find.byKey(const Key('dateSimRunButton')), findsOneWidget);
    },
  );

  testWidgets('low-context warning uses the backend message when present',
      (tester) async {
    final h = _Harness(readiness: {
      'name': 'Dana',
      'readiness_score': 8,
      'low_context': true,
      'message': 'Dana just joined — too little to go on for a real read.',
    });
    await tester.pumpWidget(_wrap(h.screen()));
    await _settle(tester);
    expect(find.text('Dana just joined — too little to go on for a real read.'),
        findsOneWidget);
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
    expect(find.byKey(const Key('dateSimDoneButton')), findsNothing);

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
    expect(find.byKey(const Key('dateSimDoneButton')), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

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
              profiles: ProfileService(auth: h.auth, firestore: h.fs),
            ),
            theme: theme,
          ),
        );
        await _settle(tester);
        expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
      }
    },
  );

  testWidgets(
    'a finished run can CONTINUE: more turns append to the same sim and the '
    'score refreshes (not a restart)',
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'done');
      await h.say(0, 'you', 'hey there!');
      await h.finish();
      await tester.pumpWidget(
        _wrap(
          DateSimScreen(
            uid: 'her',
            name: 'Dana',
            api: h.api,
            simId: 'sim1',
            service: DateSimService(auth: h.auth, firestore: h.fs),
            profiles: ProfileService(auth: h.auth, firestore: h.fs),
          ),
        ),
      );
      await _settle(tester);

      // Finished: both the continue action and Done are present.
      expect(find.byKey(const Key('dateSimContinueButton')), findsOneWidget);
      expect(find.byKey(const Key('dateSimDoneButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('dateSimContinueButton')));
      await _settle(tester);
      // The chooser (C) asks how many more; pick +5.
      expect(find.byKey(const Key('dateSimContinueChooser')), findsOneWidget);
      await tester.tap(find.byKey(const Key('dateSimContinueOption_5')));
      await _settle(tester);
      // It continued THIS sim, not a new one, by the chosen amount.
      expect(h.continueCalls, contains('/date-sim/sim1/continue'));
      expect(h.continueCounts, contains(5));

      // Backend plays the continuation: back to running, then more turns + a
      // fresh (higher) score — the original first message is still there.
      await h.sim.update({'status': 'running'});
      await _settle(tester);
      expect(find.byKey(const Key('dateSimContinueButton')), findsNothing);

      await h.say(1, 'them', 'haha hi! what are you into?');
      await h.say(2, 'you', 'climbing mostly, you?');
      await h.sim.update({
        'status': 'done',
        'verdict': {
          'score': 91,
          'score_label': 'Strong spark',
          'summary': 'Even better the longer you talked.',
        },
      });
      await _settle(tester);

      // APPENDED, not restarted: the original seq-0 turn is still there and the
      // new turns were added after it (the top bubble may be scrolled off the
      // viewport, so this is checked in the data, not on screen).
      final kept = await h.sim.collection('messages').orderBy('seq').get();
      expect(kept.docs.map((d) => d['seq'] as int), containsAll([0, 1, 2]));
      expect(kept.docs.first.data()['text'], 'hey there!');
      // The transcript auto-scrolls to the end; drag it back up so the middle
      // (newly appended) turn is in view for the on-screen assertion.
      await tester.drag(
        find.byKey(const Key('dateSimTranscript')),
        const Offset(0, 300),
      );
      await _settle(tester);
      expect(find.textContaining('what are you into'), findsOneWidget); // new
      expect(find.text('91'), findsOneWidget); // re-scored over the full chat
      expect(find.textContaining('Strong spark'), findsOneWidget);
      expect(find.byKey(const Key('dateSimContinueButton')), findsOneWidget);
    },
  );

  testWidgets('continue out of credits (402) opens the out-of-credits sheet',
      (tester) async {
    final h = _Harness(continueStatus: 402);
    h.simId = 'sim1';
    await h.start(status: 'done');
    await h.say(0, 'you', 'hey there!');
    await h.finish();
    await tester.pumpWidget(
      _wrap(
        DateSimScreen(
          uid: 'her',
          name: 'Dana',
          api: h.api,
          simId: 'sim1',
          service: DateSimService(auth: h.auth, firestore: h.fs),
          profiles: ProfileService(auth: h.auth, firestore: h.fs),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const Key('dateSimContinueButton')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('dateSimContinueOption_3')));
    await _settle(tester);
    // The standard out-of-credits sheet is shown; the result view stays put.
    expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
  });

  // --- C: the continue chooser asks how many, then dismisses cleanly ------- //
  testWidgets(
    'C: dismissing the continue chooser does NOT continue the sim',
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'done');
      await h.say(0, 'you', 'hey there!');
      await h.finish();
      await tester.pumpWidget(_wrap(h.screen2('sim1')));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('dateSimContinueButton')));
      await _settle(tester);
      expect(find.byKey(const Key('dateSimContinueChooser')), findsOneWidget);
      // Dismiss the sheet (tap the scrim) without choosing a count.
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);
      expect(h.continueCalls, isEmpty);
      expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
    },
  );

  // --- D: STOP halts an in-flight run -------------------------------------- //
  testWidgets(
    'D: Stop calls stop and leaves the sim view as soon as it lands',
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'running');
      await h.say(0, 'you', 'hey there!');
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => const Scaffold(body: Text('HOME')),
          ),
          GoRoute(
            path: '/date-sim/:uid',
            builder: (_, __) => h.screen2('sim1'),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.dark, routerConfig: router),
      );
      await _settle(tester);
      router.push('/date-sim/her');
      await _settle(tester);

      // While running, the Stop control is shown and the finished CTAs are not.
      expect(find.byKey(const Key('dateSimStopButton')), findsOneWidget);
      expect(find.byKey(const Key('dateSimDoneButton')), findsNothing);

      await tester.tap(find.byKey(const Key('dateSimStopButton')));
      await _settle(tester);
      expect(h.stopCalls, contains('/date-sim/sim1/stop'));

      // The user does NOT sit on the sim watching it wind down: the stop
      // lands and the view is left at once, back on the screen beneath.
      expect(find.byType(DateSimScreen), findsNothing);
      expect(find.text('HOME'), findsOneWidget);
    },
  );

  testWidgets(
    'D: a stop that lands after the run already finished says so honestly',
    (tester) async {
      final h = _Harness(stopBody: const {'status': 'already_finished'});
      h.simId = 'sim1';
      await h.start(status: 'running');
      await h.say(0, 'you', 'hey there!');
      await tester.pumpWidget(_wrap(h.screen2('sim1')));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('dateSimStopButton')));
      await _settle(tester);
      expect(h.stopCalls, contains('/date-sim/sim1/stop'));

      // No pretending the stop worked: we stay, with an honest note, and the
      // already-final result is what gets presented when the stream lands.
      expect(find.byType(DateSimScreen), findsOneWidget);
      expect(find.textContaining('already finished'), findsOneWidget);
      await h.finish();
      await _settle(tester);
      expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
    },
  );

  testWidgets('D: a failed stop keeps the user on the sim with an error', (
    tester,
  ) async {
    final h = _Harness(stopStatus: 500);
    h.simId = 'sim1';
    await h.start(status: 'running');
    await h.say(0, 'you', 'hey there!');
    await tester.pumpWidget(_wrap(h.screen2('sim1')));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('dateSimStopButton')));
    await _settle(tester);
    expect(h.stopCalls, contains('/date-sim/sim1/stop'));
    expect(find.byType(DateSimScreen), findsOneWidget);
    expect(
      find.text("Couldn't stop the conversation. Please try again."),
      findsOneWidget,
    );
    // The button is usable again (no wedged "Stopping…" state).
    expect(find.byKey(const Key('dateSimStopButton')), findsOneWidget);
  });

  testWidgets(
    'D: a stopped sim reopens with its transcript, the stopped note, NO score',
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'running');
      await h.say(0, 'you', 'hey there!');
      await h.say(1, 'them', 'hi! good to meet you.');
      // The backend finalized the stopped run with NO verdict (unscored).
      await h.sim.update({'status': 'done', 'stopped': true});
      await tester.pumpWidget(_wrap(h.screen2('sim1')));
      await _settle(tester);

      expect(find.byKey(const Key('dateSimStoppedNote')), findsOneWidget);
      expect(find.byKey(const Key('dateSimScore')), findsNothing);
      expect(find.byKey(const Key('dateSimStopButton')), findsNothing);
    },
  );

  // --- E: RESET discards the pair's sim and returns to setup --------------- //
  testWidgets('E: Start over resets the pair and returns to the setup form', (
    tester,
  ) async {
    final h = _Harness();
    h.simId = 'sim1';
    await h.start(status: 'done');
    await h.say(0, 'you', 'hey there!');
    await h.finish();
    await tester.pumpWidget(_wrap(h.screen2('sim1')));
    await _settle(tester);
    expect(find.byKey(const Key('dateSimScore')), findsOneWidget);

    await tester.tap(find.byKey(const Key('dateSimResetButton')));
    await _settle(tester);
    // Confirm the reset.
    expect(find.byKey(const Key('dateSimResetDialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('dateSimResetConfirmButton')));
    await _settle(tester);

    expect(h.resetCalls, contains('/date-sim/pair/her'));
    // Back at the setup form (fresh run), the result view is gone.
    expect(find.byKey(const Key('dateSimScore')), findsNothing);
    expect(find.byKey(const Key('dateSimRunButton')), findsOneWidget);
  });

  testWidgets('E: cancelling Start over keeps the result and does not reset', (
    tester,
  ) async {
    final h = _Harness();
    h.simId = 'sim1';
    await h.start(status: 'done');
    await h.say(0, 'you', 'hey there!');
    await h.finish();
    await tester.pumpWidget(_wrap(h.screen2('sim1')));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('dateSimResetButton')));
    await _settle(tester);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(h.resetCalls, isEmpty);
    expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
  });

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

  testWidgets(
    'R2-H6: tapping ✨ when a completed sim with this person exists reopens '
    'that sim (carries its sim_id) instead of a fresh setup',
    (tester) async {
      final auth = MockFirebaseAuth(signedIn: true);
      final uid = auth.currentUser!.uid;
      final fs = FakeFirebaseFirestore();
      // A past COMPLETED sim with "her" already persisted by the backend.
      await fs
          .collection('users')
          .doc(uid)
          .collection('date_sims')
          .doc('simDone')
          .set({
        'status': 'done',
        'other_uid': 'her',
        'completed_at': Timestamp.now(),
        'persona': {'name': 'Dana'},
      });

      final pushed = <String>[];
      final api = ApiClient(
        auth: auth,
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
              'sections': const [],
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
            builder: (_, s) => PublicProfileScreen(
              uid: s.pathParameters['uid']!,
              api: api,
              dateSims: DateSimService(auth: auth, firestore: fs),
            ),
          ),
          GoRoute(
            path: '/date-sim/:uid',
            builder: (_, s) {
              pushed.add(s.uri.toString());
              return const Scaffold(body: Text('DATE SIM'));
            },
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('profileDateSimButton')));
      await _settle(tester);

      // Reopened THAT sim: the route carries the persisted sim id, so the
      // screen lands on the result rather than a fresh setup form.
      expect(pushed, isNotEmpty);
      expect(pushed.single, startsWith('/date-sim/her'));
      expect(pushed.single, contains('sim_id=simDone'));
    },
  );

  // --- Done exits the finished sim to the origin profile ------------------- //
  testWidgets(
    'F: Done on a finished sim returns to the profile it was started from',
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'done');
      await h.say(0, 'you', 'hey there!');
      await h.finish();
      final router = GoRouter(
        initialLocation: '/profile/user/her',
        routes: [
          GoRoute(
            path: '/profile/user/:uid',
            builder: (_, s) => Scaffold(
              body: Text('PROFILE ${s.pathParameters['uid']}'),
            ),
          ),
          GoRoute(
            path: '/date-sim/:uid',
            builder: (_, __) => h.screen2('sim1'),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.dark, routerConfig: router),
      );
      await _settle(tester);

      // Started from Dana's profile, like the profile rail button does.
      router.push('/date-sim/her', extra: {'name': 'Dana'});
      await _settle(tester);
      expect(find.byKey(const Key('dateSimScore')), findsOneWidget);

      await tester.tap(find.byKey(const Key('dateSimDoneButton')));
      await _settle(tester);

      // Back on Dana's profile — never back into the finished sim.
      expect(find.text('PROFILE her'), findsOneWidget);
      expect(find.byType(DateSimScreen), findsNothing);
    },
  );

  testWidgets(
    'F: Done on a cold-opened sim (notification/deep link) navigates to '
    "that person's profile",
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'done');
      await h.say(0, 'you', 'hey there!');
      await h.finish();
      final router = GoRouter(
        initialLocation: '/date-sim/her?sim_id=sim1',
        routes: [
          GoRoute(
            path: '/profile/user/:uid',
            builder: (_, s) => Scaffold(
              body: Text('PROFILE ${s.pathParameters['uid']}'),
            ),
          ),
          GoRoute(
            path: '/date-sim/:uid',
            builder: (_, __) => h.screen2('sim1'),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.dark, routerConfig: router),
      );
      await _settle(tester);
      expect(find.byKey(const Key('dateSimScore')), findsOneWidget);

      await tester.tap(find.byKey(const Key('dateSimDoneButton')));
      await _settle(tester);

      // No profile beneath (cold open): navigate to the sim person's profile.
      expect(find.text('PROFILE her'), findsOneWidget);
      expect(find.byType(DateSimScreen), findsNothing);
    },
  );

  // --- Notification deep link pins: ?sim_id= -> sim result (warm + cold) --- //
  testWidgets(
    'G: warm notification tap (date_sim deep link) reopens the stored result',
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'done');
      await h.say(0, 'you', 'hey there!');
      await h.say(1, 'them', 'hi back!');
      await h.finish();
      // The finished-sim notification's deep link carries the exact sim id as
      // a query param on the sim route.
      final route = deepLinkToRoute('date_sim/her/sim1', myUid: 'me');
      expect(route, '/date-sim/her?sim_id=sim1&from=notification');
      final router = GoRouter(
        initialLocation: '/profile/user/her',
        routes: _simRoutes(h),
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.dark, routerConfig: router),
      );
      await _settle(tester);

      // Warm tap: the notification centre pushes the deep-link route on top.
      navigateToRoute(route, router: router);
      await _settle(tester);

      // THAT stored sim's result — score + summary + transcript.
      expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
      expect(find.text('78'), findsOneWidget);
      expect(
        find.text('You two kept it light and curious — a promising start.'),
        findsOneWidget,
      );
      expect(find.text('hey there!'), findsOneWidget);
      expect(find.text('hi back!'), findsOneWidget);
    },
  );

  testWidgets(
    'G: cold notification open (date_sim deep link) shows the stored result '
    "and Done lands on that person's profile",
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'done');
      await h.say(0, 'you', 'hey there!');
      await h.finish();
      final router = GoRouter(
        // Cold open: the deep link IS the initial location (fresh stack).
        initialLocation: deepLinkToRoute('date_sim/her/sim1', myUid: 'me'),
        routes: _simRoutes(h),
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.dark, routerConfig: router),
      );
      await _settle(tester);
      expect(find.byKey(const Key('dateSimScore')), findsOneWidget);
      expect(find.text('78'), findsOneWidget);

      await tester.tap(find.byKey(const Key('dateSimDoneButton')));
      await _settle(tester);

      expect(find.text('PROFILE her'), findsOneWidget);
      expect(find.byType(DateSimScreen), findsNothing);
    },
  );

  testWidgets(
    'G: a confirmed-absent sim shows the honest empty-state, with Done to '
    'the origin profile',
    (tester) async {
      final h = _Harness();
      // No sim doc is ever written: a Start-over wipe deleted it while its
      // completion notification still dangles.
      final router = GoRouter(
        initialLocation: deepLinkToRoute('date_sim/her/gone', myUid: 'me'),
        routes: _simRoutes(h),
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.dark, routerConfig: router),
      );
      await _settle(tester);

      expect(find.text('This sim is no longer available'), findsOneWidget);
      expect(find.byKey(const Key('dateSimMissingMessage')), findsOneWidget);
      expect(find.byKey(const Key('dateSimTyping')), findsNothing);
      expect(find.byKey(const Key('dateSimDoneButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('dateSimDoneButton')));
      await _settle(tester);

      expect(find.text('PROFILE her'), findsOneWidget);
      expect(find.byType(DateSimScreen), findsNothing);
    },
  );

  testWidgets(
    'G: the missing copy never shows while the doc is still loading',
    (tester) async {
      final h = _Harness();
      final sims = _GatedSims(auth: h.auth, firestore: h.fs);
      await tester.pumpWidget(
        _wrap(
          DateSimScreen(
            uid: 'her',
            name: 'Dana',
            api: h.api,
            simId: 'sim1',
            service: sims,
            profiles: ProfileService(auth: h.auth, firestore: h.fs),
          ),
        ),
      );
      await _settle(tester);

      // No emission yet: still honestly loading.
      expect(find.text('Starting the conversation…'), findsOneWidget);
      expect(find.text('This sim is no longer available'), findsNothing);

      // Confirmed absent: the honest empty-state replaces the loader.
      sims.simController.add(null);
      await _settle(tester);
      expect(find.text('This sim is no longer available'), findsOneWidget);
      expect(find.byKey(const Key('dateSimTyping')), findsNothing);

      await sims.simController.close();
      await sims.msgController.close();
    },
  );

  // --- H: a notification-opened sim exits Done to the profile, never the - //
  // --- screen beneath (Scout 2289: Done popped to the Notifications list) - //
  testWidgets(
    'H: cold notification open (shell beneath, pushed like production) — '
    'Done lands on the profile, not the shell',
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'done');
      await h.say(0, 'you', 'hey there!');
      await h.finish();
      // Production cold open: the app boots to the `/` shell, then the
      // DeepLinkQueue navigate pushes the deep-link route on top — so
      // `canPop()` is TRUE beneath the sim (the G tests' bare
      // initialLocation had nothing beneath, which is why they missed this).
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('SHELL'))),
          ..._simRoutes(h),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.dark, routerConfig: router),
      );
      await _settle(tester);

      navigateToRoute(deepLinkToRoute('date_sim/her/sim1', myUid: 'me'),
          router: router);
      await _settle(tester);
      expect(find.byKey(const Key('dateSimScore')), findsOneWidget);

      await tester.tap(find.byKey(const Key('dateSimDoneButton')));
      await _settle(tester);

      expect(find.text('PROFILE her'), findsOneWidget);
      expect(find.byType(DateSimScreen), findsNothing);
    },
  );

  testWidgets(
    'H: warm bell tap (Notifications list beneath) — Done lands on the '
    'profile, not the list',
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'done');
      await h.say(0, 'you', 'hey there!');
      await h.finish();
      final router = GoRouter(
        initialLocation: '/notifications',
        routes: [
          GoRoute(
            path: '/notifications',
            builder: (_, __) => const Scaffold(body: Text('NOTIFICATIONS')),
          ),
          ..._simRoutes(h),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.dark, routerConfig: router),
      );
      await _settle(tester);

      // Warm tap: the notification centre pushes the deep-link route on top
      // of the list.
      navigateToRoute(deepLinkToRoute('date_sim/her/sim1', myUid: 'me'),
          router: router);
      await _settle(tester);
      expect(find.byKey(const Key('dateSimScore')), findsOneWidget);

      await tester.tap(find.byKey(const Key('dateSimDoneButton')));
      await _settle(tester);

      expect(find.text('PROFILE her'), findsOneWidget);
      expect(find.text('NOTIFICATIONS'), findsNothing);
      expect(find.byType(DateSimScreen), findsNothing);
    },
  );

  testWidgets(
    'H: dangling-notification empty-state (Notifications list beneath) — '
    'Done lands on the profile, not the list',
    (tester) async {
      final h = _Harness();
      // No sim doc is ever written: a Start-over wipe deleted it while its
      // completion notification still dangles.
      final router = GoRouter(
        initialLocation: '/notifications',
        routes: [
          GoRoute(
            path: '/notifications',
            builder: (_, __) => const Scaffold(body: Text('NOTIFICATIONS')),
          ),
          ..._simRoutes(h),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.dark, routerConfig: router),
      );
      await _settle(tester);

      navigateToRoute(deepLinkToRoute('date_sim/her/gone', myUid: 'me'),
          router: router);
      await _settle(tester);
      expect(find.text('This sim is no longer available'), findsOneWidget);

      await tester.tap(find.byKey(const Key('dateSimDoneButton')));
      await _settle(tester);

      expect(find.text('PROFILE her'), findsOneWidget);
      expect(find.text('NOTIFICATIONS'), findsNothing);
      expect(find.byType(DateSimScreen), findsNothing);
    },
  );

  testWidgets(
    'date sim jobs-pass: setup insets, stepper touch targets, and run button height',
    (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_wrap(h.screen()));
      await _settle(tester);

      // Defect 11: Setup padding has 20 horizontal edge
      final setupScroll = tester.widget<SingleChildScrollView>(
          find.byType(SingleChildScrollView).first);
      expect(setupScroll.padding, const EdgeInsets.fromLTRB(20, 24, 20, 24));

      // Stepper touch targets >= 48
      final decSize =
          tester.getSize(find.byKey(const Key('dateSimCountDecrement')));
      expect(decSize.height, greaterThanOrEqualTo(48));
      expect(decSize.width, greaterThanOrEqualTo(48));

      final incSize =
          tester.getSize(find.byKey(const Key('dateSimCountIncrement')));
      expect(incSize.height, greaterThanOrEqualTo(48));
      expect(incSize.width, greaterThanOrEqualTo(48));

      // Run button height >= 52
      final runSize = tester.getSize(find.byKey(const Key('dateSimRunButton')));
      expect(runSize.height, greaterThanOrEqualTo(52));
    },
  );

  testWidgets(
    'date sim jobs-pass: live transcript insets and stop button height',
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'running');
      await h.say(0, 'you', 'hey');
      await tester.pumpWidget(_wrap(h.screen2('sim1')));
      await _settle(tester);

      final transcriptList =
          tester.widget<ListView>(find.byKey(const Key('dateSimTranscript')));
      expect(transcriptList.padding, const EdgeInsets.fromLTRB(20, 16, 20, 16));

      // Live Stop button height >= 52
      final stopSize =
          tester.getSize(find.byKey(const Key('dateSimStopButton')));
      expect(stopSize.height, greaterThanOrEqualTo(52));
    },
  );

  testWidgets(
    'date sim jobs-pass: finished footer insets, button heights, and reset target',
    (tester) async {
      final h = _Harness();
      h.simId = 'sim1';
      await h.start(status: 'done');
      await h.say(0, 'you', 'hey');
      await h.finish();
      await tester.pumpWidget(_wrap(h.screen2('sim1')));
      await _settle(tester);

      final resetSize =
          tester.getSize(find.byKey(const Key('dateSimResetButton')));
      expect(resetSize.height, greaterThanOrEqualTo(48));
      expect(resetSize.width, greaterThanOrEqualTo(48));

      final continueSize =
          tester.getSize(find.byKey(const Key('dateSimContinueButton')));
      expect(continueSize.height, greaterThanOrEqualTo(52));

      final doneSize =
          tester.getSize(find.byKey(const Key('dateSimDoneButton')));
      expect(doneSize.height, greaterThanOrEqualTo(52));
    },
  );
}
