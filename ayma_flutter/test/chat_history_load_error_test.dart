import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// GATE-RED regression: when the Ayma chat tab's `/chat/history` load fails,
/// the screen must render the graceful "Couldn't load…" + Retry state and
/// must NOT corrupt the element tree — the failure used to surface as a solid
/// red `ErrorWidget` block from framework assertions (`_children.contains` /
/// `_elements.contains`) raised mid-rebuild.
const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

final _base = DateTime.utc(2026, 1, 1);
final _history = List<Map<String, String>>.generate(90, (i) {
  return {
    'role': i.isEven ? 'user' : 'ayma',
    'text': 'hist message $i',
    'created_at': _base.add(Duration(minutes: i)).toIso8601String(),
  };
});

void main() {
  tearDown(() => ChatInbox.instance.take());

  testWidgets(
      'initial history load failure shows the graceful error, never an ErrorWidget',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Every `/chat/history` call fails: the injectable ApiClient is the
    // screen's own failure seam (no network, no auth guesswork).
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response('boom', 500, headers: _jsonUtf8);
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    // (1) the graceful error state is shown.
    expect(find.text("Couldn't load your conversation history."),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // (2) no element-tree corruption: no ErrorWidget, no framework exception.
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);

    // Retry that fails again must stay graceful too (no residual corruption).
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load your conversation history."),
        findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a slow/cold backend: the first history calls fail then succeed — stays '
      'on LOADING and recovers, NEVER a hard error on the first timeout',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Models a scale-to-zero cold start: the first two `/chat/history` calls
    // fail transiently (503), the third (warm) succeeds.
    var calls = 0;
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        calls++;
        if (calls <= 2) {
          return http.Response('cold', 503, headers: _jsonUtf8);
        }
        final page = _history.sublist(_history.length - 40);
        return http.Response(
          jsonEncode({'messages': page, 'next_before': null}),
          200,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    // One frame: the first load has failed and a retry is scheduled. The
    // screen must still be LOADING — never the hard-fail error on attempt 1.
    await tester.pump();
    expect(find.text("Couldn't load your conversation history."), findsNothing);

    // Ride out the backoff into the successful (warm) attempt.
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load your conversation history."), findsNothing);
    expect(find.text('hist message 89'), findsOneWidget);
    expect(calls, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a retrying history load surfaces the Reconnecting line instead of '
      'holding the original line', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Loader retest (Scout, Nov 2026, Leg 4): with the network cut, the chat
    // line held "Loading your conversation…" indefinitely with no retry
    // signal. Models a cold backend: the first two `/chat/history` calls fail
    // transiently (503), the third (warm) succeeds. Two failures, because
    // ApiClient's own bounded GET retry absorbs the first 503 internally —
    // the cold-start backoff (and its retry signal) starts when the whole
    // load attempt fails.
    var calls = 0;
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        calls++;
        if (calls <= 2) {
          return http.Response('cold', 503, headers: _jsonUtf8);
        }
        final page = _history.sublist(_history.length - 40);
        return http.Response(
          jsonEncode({'messages': page, 'next_before': null}),
          200,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    // The first load attempt has failed (past ApiClient's internal 300ms
    // absorb) and the 1s cold-start backoff is elapsing: the loader must say
    // so instead of holding the original line.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Reconnecting…'), findsOneWidget);

    // The retry succeeds and history lands as before.
    await tester.pumpAndSettle();
    expect(find.text('hist message 89'), findsOneWidget);
    expect(calls, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'an older-page history load failure flips the loader row without ErrorWidget',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The first (newest) page succeeds -> a GlobalKey-ed transcript list is
    // on screen; every *older* page then fails, flipping `_loadingOlder`
    // on then off while those keyed turn rows are mounted. Before the fix the
    // loader/divider rows were unkeyed, so each flip shifted the keyed turns'
    // index and forced GlobalKey moves mid-rebuild — the GATE-RED crash.
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        final before = request.url.queryParameters['before'];
        if (before != null) {
          return http.Response('boom', 500, headers: _jsonUtf8);
        }
        final page = _history.sublist(_history.length - 40);
        return http.Response(
          jsonEncode(
              {'messages': page, 'next_before': page.first['created_at']}),
          200,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('hist message 89'), findsOneWidget);
    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;

    // Repeatedly drive to the top: each tick kicks off an older-page fetch
    // that fails, flipping the loader row on and off.
    for (var i = 0; i < 6; i++) {
      controller.jumpTo(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    // The keyed loader/divider rows keep the transcript list stable: no
    // ErrorWidget and no framework assertion from the loader flips.
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
    // The transcript list is intact (not torn down into an error state), with
    // a loaded turn near the scrolled-to top still realized.
    expect(find.byType(ListView), findsOneWidget);
    expect(find.text('hist message 50'), findsOneWidget);
  });
}
