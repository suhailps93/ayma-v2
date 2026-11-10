import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_wing_loader.dart';
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
  testWidgets('pre-selects the default brain and does not show description under dropdown',
      (tester) async {
    await tester.pumpWidget(_host(BrainSelectorControl(api: _api())));
    await tester.pumpAndSettle();

    // Nothing saved → the default (Muse) is shown selected.
    // The description line under the dropdown is no longer rendered (Nov 8 founder order).
    expect(find.text('Meta Muse Spark'), findsOneWidget);
    expect(find.textContaining('fall back to Gemini'), findsNothing);
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

  testWidgets(
      'a slow/cold backend on the brain load: stays on the spinner and '
      'recovers — never the hard "Could not load brains" error', (tester) async {
    // Addendum (2026-11-03): the cold staging backend 408'd the first
    // /brain/preference load into a hard error. It must ride the cold start.
    final api = _ColdBrainApi(failCall: (n) => n == 1);

    await tester.pumpWidget(_host(BrainSelectorControl(api: api)));
    await tester.pump(); // first load failed, retry scheduled
    expect(find.byKey(const ValueKey('brain-selector-error')), findsNothing);
    expect(find.byType(AymaWingLoader), findsOneWidget);

    await tester.pumpAndSettle(); // ride backoff into the warm load
    expect(find.byKey(const ValueKey('brain-selector-error')), findsNothing);
    expect(find.text('Meta Muse Spark'), findsOneWidget);
    expect(api.calls, 2);
  });

  testWidgets(
      'a genuinely-unreachable brain backend ends on error + Retry, and Retry '
      'restarts the load', (tester) async {
    final api = _ColdBrainApi(failCall: (_) => true);

    await tester.pumpWidget(_host(BrainSelectorControl(api: api)));
    await tester.pumpAndSettle(); // exhaust the budget
    expect(find.byKey(const ValueKey('brain-selector-error')), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    api.down = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brain-selector-error')), findsNothing);
    expect(find.text('Meta Muse Spark'), findsOneWidget);
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

  // --- Jobs pass cluster 18 (fleet/jobs-models-reaudit) ---

  testWidgets('V13: brain dropdown border is the boundary token', (tester) async {
    await tester.pumpWidget(_host(BrainSelectorControl(api: _api())));
    await tester.pumpAndSettle();

    final ac = tester.element(find.byType(BrainSelectorControl)).ac;
    final container = tester.widget<Container>(find
        .ancestor(
            of: find.byKey(const ValueKey('brain-dropdown')),
            matching: find.byType(Container))
        .first);
    final border = (container.decoration as BoxDecoration).border as Border;
    expect(border.top.color, ac.boundary);
  });

  testWidgets('V6/V7: picker info button is 48x48 and the label tracks at 2',
      (tester) async {
    await tester.pumpWidget(_host(BrainSelectorControl(api: _api())));
    await tester.pumpAndSettle();

    final iconButton = tester.widget<IconButton>(find.descendant(
        of: find.byType(BrainSelectorControl), matching: find.byType(IconButton)));
    expect(iconButton.constraints,
        const BoxConstraints(minWidth: 48, minHeight: 48));

    final label = tester.widget<Text>(find.text('BRAIN'));
    expect(label.style?.letterSpacing, 2);
  });

  testWidgets('V1/V4: load error uses errorText and Retry shares the left edge',
      (tester) async {
    final api = _ColdBrainApi(failCall: (_) => true);
    await tester.pumpWidget(_host(BrainSelectorControl(api: api)));
    await tester.pumpAndSettle();

    final ac = tester.element(find.byType(BrainSelectorControl)).ac;
    final errorText = tester.widget<Text>(find.textContaining('Could not load brains'));
    expect(errorText.style?.color, ac.errorText);

    // Retry affordance at the same left edge as the error text (defect 4: zero
    // inset). Measure the Retry BUTTON — the box whose `padding: EdgeInsets.zero`
    // we control — not the label glyph: the label sits centred inside the
    // TextButton's 48px min-interactive tap target, so the label's own left is
    // offset by (buttonWidth − glyphWidth)/2, a value that moves with font
    // metrics (5.25px once the real fonts bundled in batch 2421 load). The
    // button's left edge is font-independent and is the real guarantee.
    final errorLeft =
        tester.getTopLeft(find.textContaining('Could not load brains')).dx;
    final retryButton = find.ancestor(
        of: find.text('Retry'), matching: find.byType(TextButton));
    expect(tester.getTopLeft(retryButton).dx,
        moreOrLessEquals(errorLeft, epsilon: 0.5));

    // And `padding: EdgeInsets.zero` adds no asymmetric left indent: the label
    // is centred within the button (left inset == right inset), font-robustly.
    final buttonRect = tester.getRect(retryButton);
    final labelRect = tester.getRect(find.text('Retry'));
    expect(labelRect.left - buttonRect.left,
        moreOrLessEquals(buttonRect.right - labelRect.right, epsilon: 0.5));
  });
}

/// An [ApiClient] controlling `/brain/preference` at the LOGICAL call level, so
/// a test drives cold-start failures deterministically (the HTTP layer's own
/// 5xx inner-retry would otherwise double-count a MockClient's calls).
class _ColdBrainApi extends ApiClient {
  _ColdBrainApi({required this.failCall})
      : super(
          httpClient: MockClient((req) async => http.Response(
              jsonEncode({'ok': true}), 200,
              headers: const {'content-type': 'application/json'})),
          auth: MockFirebaseAuth(signedIn: true),
        );

  final bool Function(int call) failCall;
  bool down = true;
  int calls = 0;

  @override
  Future<BrainCatalog> brainPreference({Duration? timeout}) async {
    calls++;
    if (down && failCall(calls)) {
      throw ApiException('Request timed out — please try again.',
          statusCode: 503);
    }
    return BrainCatalog.fromMap(_catalog());
  }
}
