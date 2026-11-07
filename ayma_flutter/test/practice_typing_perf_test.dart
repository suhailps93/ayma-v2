import 'dart:convert';
import 'dart:math' as math;

import 'package:ayma_flutter/features/practice_date/practice_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Regression guard for the NOTE 133 ANR (2026-11-07 02:41, build 2332):
/// a KeyEvent waited 5001 ms while typing into the practice composer and
/// the process was killed. The ANR trace names no blocking call (every
/// thread idle by dump time), so this test locks the property the
/// investigation established about the typing path itself: one
/// keystroke's frame on the practice screen is a few ms and — the part a
/// future change could silently break — its cost does NOT grow with the
/// conversation history. If typing ever starts rebuilding or laying out
/// the message list per keystroke (a controller listener that setStates
/// the screen, a non-lazy list, a per-keystroke formatter over the whole
/// transcript), the long-history keystroke stops being flat and this
/// test fails.
///
/// Costs are real CPU (Stopwatch around the frame the keystroke
/// produces); taking the MINIMUM of several rounds keeps the comparison
/// honest on a loaded host — a hiccup inflates a round, never the min.
ApiClient _api() => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path == '/practice/start') {
          return http.Response(
            jsonEncode({
              'session_id': 'practice_1',
              'simulation': true,
              'persona': {
                'name': 'Dana',
                'age': 30,
                'location': 'Berlin',
                'photo_count': 2,
              },
              'banner':
                  "Practice mode — you're talking to a simulated version of Dana, not the real person.",
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path == '/practice/chat') {
          return http.Response(
            jsonEncode({
              'reply': 'That is nice, tell me more about yourself and '
                  'what you like to do on weekends.',
              'coach_hint': 'Ask a follow-up.',
              'simulation': true,
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('no', 404);
      }),
    );

void main() {
  testWidgets('practice typing cost stays flat as the history grows',
      (tester) async {
    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: AymaTheme.dark,
        home: PracticeScreen(uid: 'her', api: _api()),
      ),
    );
    await settle();
    final field = find.byType(TextField);
    expect(field, findsOneWidget);

    // The cheapest of [rounds] keystroke frames (enterText = one text
    // update + the frame it schedules), in milliseconds.
    Future<int> keystrokeCost() async {
      var best = 1 << 30;
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        await tester.enterText(field, 'x' * (i + 1));
        await tester.pump();
        sw.stop();
        best = math.min(best, sw.elapsedMilliseconds);
      }
      await tester.enterText(field, '');
      await tester.pump();
      return best;
    }

    // Warm-up so first-layout costs don't pollute the empty baseline.
    await keystrokeCost();
    final emptyMs = await keystrokeCost();

    // 60 sends = 120 bubbles of history.
    for (var i = 0; i < 60; i++) {
      await tester.enterText(field, 'Hello Dana, message number $i here.');
      await tester.tap(find.byKey(const ValueKey('practiceSendButton')));
      await settle();
    }

    final longMs = await keystrokeCost();

    // Catastrophe bound: even on a slow host a single keystroke frame
    // must stay far away from input-dispatch territory.
    expect(longMs, lessThan(500),
        reason: 'one keystroke frame with 120 bubbles took ${longMs}ms');
    // The flatness property: history must not tax typing. A per-keystroke
    // rebuild of 120 bubbles costs tens of ms in a debug test build —
    // far past this margin over the empty-history cost.
    expect(longMs, lessThan(emptyMs + 25),
        reason: 'keystroke frame grew from ${emptyMs}ms (empty history) '
            'to ${longMs}ms (120 bubbles) — typing is paying for history');
  });
}
