import 'dart:convert';

import 'package:ayma_flutter/screens/wiki_notes_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/markdown_text.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _api(Map<String, dynamic> body) {
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/wiki/ai-view') {
      return http.Response(jsonEncode(body), 200);
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets('renders the notes as markdown, not literal ### ', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api({
      'text': '### Career\n\nWorks in **design**.',
      'photos': <dynamic>[],
    });

    await tester.pumpWidget(MaterialApp(home: WikiNotesScreen(apiClient: api)));
    await tester.pumpAndSettle();

    // rendered through the markdown widget, not a raw SelectableText dump
    expect(find.byType(MarkdownText), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    // the heading + bold text render, but their markdown syntax is gone
    expect(find.textContaining('Career'), findsWidgets);
    expect(find.textContaining('design'), findsWidgets);
    expect(find.textContaining('###'), findsNothing);
    expect(find.textContaining('**'), findsNothing);
  });

  testWidgets('shows a thumbnail for every photo Ayma has', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api({
      'text': 'some notes',
      'photos': [
        {'url': 'https://cdn.example/p1.jpg', 'source': 'profile'},
        {'url': 'https://cdn.example/p2.jpg', 'source': 'profile'},
        {'url': 'https://cdn.example/c1.jpg', 'source': 'chat'},
      ],
    });

    await tester.pumpWidget(MaterialApp(home: WikiNotesScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('PHOTOS AYMA HAS (3)'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(3));
    expect(find.text('CHAT'), findsOneWidget);
    expect(find.text('PROFILE'), findsNWidgets(2));
  });

  testWidgets('"Copy all" copies the raw notes text', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    final api = _api({
      'text': '### Career\n\nWorks in **design**.',
      'photos': <dynamic>[],
    });

    await tester.pumpWidget(MaterialApp(home: WikiNotesScreen(apiClient: api)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Copy all'));
    await tester.pumpAndSettle();

    expect(copied, '### Career\n\nWorks in **design**.');
  });
}
