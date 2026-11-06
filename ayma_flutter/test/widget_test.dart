import 'dart:convert';

import 'package:ayma_flutter/routing/entry.dart';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/screens/preboarding_flow_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _apiWithHistory(
  http.Response Function(http.Request request) onHistory,
) {
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/chat/history') return onHistory(request);
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  test('entryRouteFor maps every session_mode to a real screen path', () {
    expect(entryRouteFor('active'), MainShellScreen.path);
    expect(entryRouteFor('interview'), PreboardingFlowScreen.path);
    expect(entryRouteFor('marketing'), ChatScreen.path);
    expect(entryRouteFor('anything-else'), ChatScreen.path);
    // A missing/empty mode is a malformed response, not "pre-signup" — a
    // signed-in user must not be dumped into the marketing chat.
    expect(entryRouteFor(''), MainShellScreen.path);
  });

  testWidgets('chat shell renders and accepts typed text', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _apiWithHistory(
      (_) => http.Response(
          jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200),
    );

    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('Say hello to start a conversation.'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // WhatsApp composer model (founder, 2026-11-06): with an empty input
    // the send slot is the voice mic (Step 14's mic, in its new home).
    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hello ayma');
    await tester.pump();
    expect(find.text('hello ayma'), findsOneWidget);

    // Once text is typed the slot swaps to SEND and the mic is gone.
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
  });

  testWidgets(
      'a persistent history failure shows a distinct error + retry, not '
      '"say hello"', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var calls = 0;
    var recovered = false;
    // Every attempt fails (a persistent 5xx) until the backend recovers. The
    // bounded auto-retry (PERF_PLAN Phase 1) can't paper over a persistent
    // failure, so the graceful error + Retry state MUST still show — auto-retry
    // must not swallow it (GATE-RED / P2).
    final api = _apiWithHistory((_) {
      calls++;
      if (recovered) {
        return http.Response(
            jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200);
      }
      return http.Response('nope', 503);
    });

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull); // no red ErrorWidget
    // Not the empty-history copy — a real error with a way to recover.
    expect(find.text('Say hello to start a conversation.'), findsNothing);
    expect(
        find.text("Couldn't load your conversation history."), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
    expect(calls, greaterThanOrEqualTo(2)); // the load was auto-retried

    // Manual Retry on a now-healthy backend recovers to the empty state.
    recovered = true;
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(
        find.text("Couldn't load your conversation history."), findsNothing);
    expect(find.text('Say hello to start a conversation.'), findsOneWidget);
  });

  testWidgets('a transient history 5xx auto-recovers with no error UI',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var calls = 0;
    // A single transient 503, then 200: the bounded retry recovers it, so the
    // user never sees the error state (PERF_PLAN Phase 1).
    final api = _apiWithHistory((_) {
      calls++;
      if (calls == 1) return http.Response('nope', 503);
      return http.Response(
          jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200);
    });

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(calls, 2); // one auto-retry, then success
    expect(tester.takeException(), isNull);
    expect(
        find.text("Couldn't load your conversation history."), findsNothing);
    expect(find.text('Say hello to start a conversation.'), findsOneWidget);
  });

  testWidgets('history turns from the server seed the transcript on open',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _apiWithHistory(
      (_) => http.Response(
        jsonEncode({
          'messages': [
            {'role': 'user', 'text': 'hey from last week', 'image_path': ''},
            {'role': 'ayma', 'text': 'welcome back', 'image_path': ''},
          ],
          'next_before': null,
        }),
        200,
      ),
    );

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('Say hello to start a conversation.'), findsNothing);
    expect(find.text('hey from last week'), findsOneWidget);
    expect(find.text('welcome back'), findsOneWidget);
  });

  testWidgets('an Ayma turn ending with a [face_report:id] marker strips it '
      'from the shown text', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _apiWithHistory(
      (_) => http.Response(
        jsonEncode({
          'messages': [
            {
              'role': 'ayma',
              'text': 'Here is your read. [face_report:abc123]',
              'image_path': '',
            },
          ],
          'next_before': null,
        }),
        200,
      ),
    );

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    // The marker is stripped; the inline report card fetches the stored
    // report itself (and shows nothing if there isn't one).
    expect(find.textContaining('Here is your read'), findsOneWidget);
    expect(find.textContaining('face_report'), findsNothing);
  });

  testWidgets('a [deep_dive:id] marker shows a tappable card to /deep-dive/:id',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _apiWithHistory(
      (_) => http.Response(
        jsonEncode({
          'messages': [
            {
              'role': 'ayma',
              'text': 'Here is what the web says. [deep_dive:uid_x]',
              'image_path': '',
            },
          ],
          'next_before': null,
        }),
        200,
      ),
    );

    var opened = '';
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => ChatScreen(apiClient: api)),
        GoRoute(
          path: '/deep-dive/:id',
          builder: (_, s) {
            opened = s.pathParameters['id']!;
            return const Scaffold(body: Text('RESEARCH'));
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.textContaining('Here is what the web says'), findsOneWidget);
    expect(find.textContaining('deep_dive'), findsNothing);

    await tester.tap(find.text('Web research report'));
    await tester.pumpAndSettle();
    expect(opened, 'uid_x');
    expect(find.text('RESEARCH'), findsOneWidget);
  });

  testWidgets(
      'a finished match lands in an open chat as a score card that opens '
      'the match report', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Founder bug 2026-10-26: the match only pushed a notification. Now the
    // server writes a `[match:<id>]` turn; an open chat pulls it in as soon
    // as the app sees the match land.
    var matchDone = false;
    final api = ApiClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/chat/history') {
          return http.Response(
            jsonEncode({
              'messages': [
                if (matchDone)
                  {
                    'role': 'ayma',
                    'text': 'Your match with Dillu is ready: 41%.\n\n'
                        '[match:a__b]',
                    'image_path': '',
                    'tools': ['Checked your match with Dillu'],
                    'created_at': '2026-10-26T01:40:39Z',
                  },
              ],
              'next_before': null,
            }),
            200,
          );
        }
        if (request.url.path == '/match/a__b') {
          return http.Response(jsonEncode({'score': 0.41}), 200);
        }
        return http.Response('{}', 200);
      }),
      auth: MockFirebaseAuth(signedIn: true),
    );

    var opened = '';
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => ChatScreen(apiClient: api)),
        GoRoute(
          path: '/match/:id',
          builder: (_, s) {
            opened = s.pathParameters['id']!;
            return const Scaffold(body: Text('MATCH REPORT'));
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.textContaining('Match report'), findsNothing);

    matchDone = true;
    ChatInbox.instance.resultLanded();
    await tester.pumpAndSettle();

    expect(find.textContaining('Your match with Dillu is ready: 41%.'),
        findsOneWidget);
    expect(find.textContaining('[match:'), findsNothing);
    expect(find.text('Checked your match with Dillu'), findsOneWidget);
    expect(find.text('Match report · 41%'), findsOneWidget);

    await tester.tap(find.text('Match report · 41%'));
    await tester.pumpAndSettle();
    expect(opened, 'a__b');
    expect(find.text('MATCH REPORT'), findsOneWidget);
  });

  testWidgets(
      'preboarding is a single scrollable page with every field and a '
      'gated Save', (WidgetTester tester) async {
    // Tall enough that every field is laid out without needing to scroll —
    // the whole point under test is that it's all on one page at once.
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: PreboardingFlowScreen()),
    );
    await tester.pumpAndSettle();

    // One page, one title — no step counter or per-step navigation.
    expect(find.text('Tell us about you'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    expect(find.text('Finish'), findsNothing);

    // The 18+ age step comes first and gates everything else: only the date
    // of birth is on screen until an adult birthdate is confirmed.
    expect(find.byKey(const Key('preboarding_age_title')), findsOneWidget);
    expect(find.byKey(const Key('preboarding_dob')), findsOneWidget);
    expect(find.byKey(const Key('preboarding_first_name')), findsNothing);
    expect(find.text('Gender'), findsNothing);
    await tester.enterText(
        find.byKey(const Key('preboarding_dob')), '03/05/1993');
    await tester.pump();
    await tester.tap(find.byKey(const Key('preboarding_age_continue')));
    await tester.pumpAndSettle();

    // Every field/question the old 7-step wizard collected is present at
    // once, laid out like the Edit Profile screen (label above field).
    expect(find.byKey(const Key('preboarding_first_name')), findsOneWidget);
    expect(find.byKey(const Key('preboarding_last_name')), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Phone (optional)'), findsOneWidget);
    expect(find.byKey(const Key('preboarding_dob')), findsOneWidget);
    expect(find.text('Gender'), findsOneWidget);
    for (final g in ['Woman', 'Man', 'Non-binary', 'Other']) {
      expect(find.widgetWithText(ChoiceChip, g), findsOneWidget);
    }
    expect(find.text('Interested in'), findsOneWidget);
    for (final opt in ['Women', 'Men', 'Everyone']) {
      expect(find.widgetWithText(FilterChip, opt), findsOneWidget);
    }
    expect(find.byKey(const Key('preboarding_location')), findsOneWidget);
    expect(find.text('Use my current location'), findsOneWidget);
    expect(find.text('Verification selfie'), findsOneWidget);
    expect(find.text('Take a selfie'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Choose photos'), findsOneWidget);

    // A single Save button at the bottom, gated on the full question set —
    // tapping it before everything is filled explains what's missing rather
    // than silently doing nothing (the old flow's "complete this step
    // first" message, adapted to one page).
    final saveButton = find.widgetWithText(FilledButton, 'Save');
    expect(saveButton, findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('preboarding_first_name')), 'Alex');
    await tester.enterText(
        find.byKey(const Key('preboarding_last_name')), 'Rivera');
    await tester.pump();

    await tester.tap(saveButton);
    await tester.pump();
    expect(find.textContaining('Please fill in every field'), findsOneWidget);

    // Filling the rest of the typed/chip fields (birthdate, gender,
    // interested-in, location) still leaves Save gated on the selfie and
    // photos, which this test can't provide (no camera/gallery in the test
    // harness) — confirming the gate covers the whole question set, not
    // just the name fields.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Woman'));
    await tester.tap(find.widgetWithText(FilterChip, 'Everyone'));
    await tester.enterText(
        find.byKey(const Key('preboarding_location')), 'Austin, TX');
    await tester.pump();

    await tester.tap(saveButton);
    await tester.pump();
    expect(find.textContaining('Please fill in every field'), findsOneWidget);
  });

}
