import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

void main() {
  tearDown(() => ChatInbox.instance.take());

  Future<ApiClient> api() async {
    final mockHttp = MockClient.streaming((request, bodyStream) async {
      if (request.url.path == '/chat/history') {
        return http.StreamedResponse(
          Stream.value(
              utf8.encode(jsonEncode({'messages': [], 'next_before': null}))),
          200,
          headers: _jsonUtf8,
        );
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode('{}')),
        200,
        headers: _jsonUtf8,
      );
    });
    return ApiClient(
        httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
  }

  ScrollPosition pos(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!.position;

  // Push one more growing (non-final voice) segment, each sub-animation
  // (<200ms) apart — exactly how a live call feeds the transcript
  // (§1.7 step 12: applyVoiceSegment grows the tail turn in place, notifying
  // on each one). Returns the accumulated text so the caller can keep growing.
  Future<String> pushSegment(
      WidgetTester tester, TranscriptStore store, String acc, int i) async {
    final next = acc.isEmpty ? 'streamed line $i' : '$acc\nstreamed line $i';
    store.applyVoiceSegment(TurnRole.ayma, next, isFinal: false);
    await tester.pump(const Duration(milliseconds: 30));
    return next;
  }

  testWidgets('voice streaming follows the bottom DURING the stream, when the '
      'user is at the bottom', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = TranscriptStore();
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(apiClient: await api(), transcriptStore: store),
    ));
    await tester.pumpAndSettle();

    var acc = '';
    double worstGap = 0;
    for (var i = 0; i < 400; i++) {
      acc = await pushSegment(tester, store, acc, i);
      final p = pos(tester);
      if (p.maxScrollExtent > 400) {
        final gap = p.maxScrollExtent - p.pixels;
        if (gap > worstGap) worstGap = gap;
      }
    }

    // Before the fix this was thousands of px (the 200ms animate-to-bottom
    // never landing between segments). The live transcript must follow within
    // about one segment's growth.
    expect(worstGap, lessThan(200.0),
        reason: 'mid-stream lag below the bottom was $worstGap px');
  });

  testWidgets('a user scrolled up to read history mid-call is NOT yanked down '
      'by streaming voice segments', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = TranscriptStore();
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(apiClient: await api(), transcriptStore: store),
    ));
    await tester.pumpAndSettle();

    // Stream enough to build real scrollable height (following to the bottom).
    var acc = '';
    for (var i = 0; i < 200; i++) {
      acc = await pushSegment(tester, store, acc, i);
    }
    expect(pos(tester).maxScrollExtent, greaterThan(800));

    // The user scrolls up to re-read something earlier, and lets go.
    pos(tester).jumpTo(pos(tester).maxScrollExtent - 800);
    await tester.pump();
    final parked = pos(tester).pixels;

    // Segments keep streaming in below — the view must stay parked.
    var movedWhileParked = false;
    for (var i = 200; i < 400; i++) {
      acc = await pushSegment(tester, store, acc, i);
      if ((pos(tester).pixels - parked).abs() > 24) movedWhileParked = true;
    }

    expect(movedWhileParked, isFalse,
        reason: 'streaming must not yank a user who scrolled up to read '
            'history down to the bottom');
  });

  testWidgets('a typed (text-mode) reply still lands scrolled to the bottom',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = TranscriptStore();
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(apiClient: await api(), transcriptStore: store),
    ));
    await tester.pumpAndSettle();

    // Many separate turns build height the markdown-rendered bubbles can't on
    // their own (a lone long turn soft-wraps into one short paragraph).
    for (var i = 0; i < 60; i++) {
      store.addTurn(i.isEven ? TurnRole.user : TurnRole.ayma,
          'text turn number $i with a little body text', TurnSource.text);
    }
    await tester.pumpAndSettle();

    final p = pos(tester);
    expect(p.maxScrollExtent, greaterThan(0));
    expect(
      p.pixels,
      closeTo(p.maxScrollExtent, 1.0),
      reason: 'text-mode reply should land scrolled to the bottom',
    );
  });
}
