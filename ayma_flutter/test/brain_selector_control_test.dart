import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/brain_selector_control.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The unified-Brain catalog (§13.10): two vendors, nothing saved yet, Muse
/// (`meta`) as the hackathon default the UI pre-selects.
Map<String, dynamic> _catalog({String current = ''}) => {
      'brains': [
        {
          'id': 'gemini',
          'label': 'Gemini',
          'description': 'Reads images and does live web research.',
          'available': true,
          'capabilities': ['text', 'json', 'vision', 'web', 'tools'],
        },
        {
          'id': 'meta',
          'label': 'Meta Muse Spark',
          'description': 'Fast reasoning; image + web fall back to Gemini.',
          'available': true,
          'capabilities': ['text', 'json', 'tools'],
        },
      ],
      'current': current,
      'default': 'meta',
    };

final List<Map<String, dynamic>> _posted = [];

ApiClient _api({String current = ''}) {
  _posted.clear();
  final mock = MockClient((req) async {
    if (req.url.path == '/brain/preference' && req.method == 'GET') {
      return http.Response(jsonEncode(_catalog(current: current)), 200,
          headers: const {'content-type': 'application/json'});
    }
    if (req.url.path == '/brain/preference' && req.method == 'POST') {
      _posted.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response(jsonEncode({'ok': true}), 200,
          headers: const {'content-type': 'application/json'});
    }
    return http.Response('unexpected ${req.url.path}', 404);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

Widget _host(Widget child) => MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('pre-selects the default brain and shows its description',
      (tester) async {
    await tester.pumpWidget(_host(BrainSelectorControl(api: _api())));
    await tester.pumpAndSettle();

    // Nothing saved → the hackathon default (Muse) is shown selected, with its
    // description (the Gemini fallback note).
    expect(find.text('Meta Muse Spark'), findsOneWidget);
    expect(find.textContaining('fall back to Gemini'), findsOneWidget);
    expect(find.text('Save brain'), findsOneWidget);
  });

  testWidgets('a saved brain is shown selected', (tester) async {
    await tester.pumpWidget(_host(BrainSelectorControl(api: _api(current: 'gemini'))));
    await tester.pumpAndSettle();
    expect(find.text('Gemini'), findsOneWidget);
  });

  testWidgets('selecting a brain and saving posts it', (tester) async {
    await tester.pumpWidget(_host(BrainSelectorControl(api: _api())));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('brain-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gemini').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('brain-selector-save')));
    await tester.pumpAndSettle();

    expect(_posted, hasLength(1));
    expect(_posted.first['brain'], 'gemini');
  });

  testWidgets('live-updates the selection when Ayma saves a new brain',
      (tester) async {
    // Founder bug 2026-11-02: the open models screen kept showing the old brain
    // after Ayma changed+saved it. The control listens to the model-settings doc
    // and reflects the change at once.
    final fs = FakeFirebaseFirestore();
    final doc =
        fs.collection('users').doc('u1').collection('profile').doc('main');
    await doc.set({'ayma_brain_model': ''});

    await tester.pumpWidget(_host(
        BrainSelectorControl(api: _api(current: ''), firestore: fs, uid: 'u1')));
    await tester.pumpAndSettle();
    expect(find.text('Meta Muse Spark'), findsOneWidget); // default pre-selected

    await doc.set({'ayma_brain_model': 'gemini'}, SetOptions(merge: true));
    await tester.pumpAndSettle();
    expect(find.text('Gemini'), findsOneWidget);
    expect(find.text('Meta Muse Spark'), findsNothing);
  });
}
