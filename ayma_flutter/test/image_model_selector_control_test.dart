import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_wing_loader.dart';
import 'package:ayma_flutter/widgets/image_model_selector_control.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The image-model catalog (image-gen restore): Gemini-direct is the default
/// and the only entry until an xAI key is set. [extraXai] adds the xAI entry
/// (as it would appear once configured) so the dropdown has a second option;
/// [xaiAvailable] false mimics a provider the server would simply not return —
/// the UI must not list it.
Map<String, dynamic> _catalog({
  String current = '',
  bool extraXai = false,
  bool xaiAvailable = true,
}) =>
    {
      'models': [
        {
          'id': 'gemini-direct',
          'label': 'Gemini (Google)',
          'description': 'Google Gemini image model.',
          'model': 'gemini-2.5-flash-image',
          'available': true,
        },
        if (extraXai)
          {
            'id': 'xai-direct',
            'label': 'Grok Imagine (xAI)',
            'description': 'xAI Grok Imagine.',
            'model': 'grok-imagine-image-2.0',
            'available': xaiAvailable,
          },
      ],
      'current': current,
      'default': 'gemini-direct',
    };

final List<Map<String, dynamic>> _posted = [];

ApiClient _api({
  String current = '',
  bool extraXai = false,
  bool xaiAvailable = true,
}) {
  _posted.clear();
  final mock = MockClient((req) async {
    if (req.url.path == '/image-model/preference' && req.method == 'GET') {
      return http.Response(
          jsonEncode(_catalog(
              current: current, extraXai: extraXai, xaiAvailable: xaiAvailable)),
          200,
          headers: const {'content-type': 'application/json'});
    }
    if (req.url.path == '/image-model/preference' && req.method == 'POST') {
      _posted.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response(jsonEncode({'ok': true}), 200,
          headers: const {'content-type': 'application/json'});
    }
    return http.Response('unexpected ${req.url.path}', 404);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

Widget _host(Widget child, [ThemeData? theme]) => MaterialApp(
      theme: theme ?? AymaTheme.light,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('pre-selects the Gemini default when nothing is saved',
      (tester) async {
    await tester.pumpWidget(_host(ImageModelSelectorControl(api: _api())));
    await tester.pumpAndSettle();
    expect(find.text('Gemini (Google)'), findsOneWidget);
    expect(find.text('Save image model'), findsOneWidget);
  });

  testWidgets('a saved pick is shown selected', (tester) async {
    await tester.pumpWidget(_host(ImageModelSelectorControl(
        api: _api(current: 'xai-direct', extraXai: true))));
    await tester.pumpAndSettle();
    expect(find.text('Grok Imagine (xAI)'), findsOneWidget);
  });

  testWidgets('selecting a model and saving posts it', (tester) async {
    await tester.pumpWidget(
        _host(ImageModelSelectorControl(api: _api(extraXai: true))));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('image-model-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Grok Imagine (xAI)').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('image-model-selector-save')));
    await tester.pumpAndSettle();

    expect(_posted, hasLength(1));
    expect(_posted.first['image_model'], 'xai-direct');
  });

  testWidgets('an unavailable model is not listed in the dropdown',
      (tester) async {
    await tester.pumpWidget(_host(ImageModelSelectorControl(
        api: _api(extraXai: true, xaiAvailable: false))));
    await tester.pumpAndSettle();

    // The default renders; the unavailable xAI entry is filtered out.
    expect(find.text('Gemini (Google)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('image-model-dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('Grok Imagine (xAI)'), findsNothing);
  });

  testWidgets('live-updates the selection when Ayma saves a new image model',
      (tester) async {
    final fs = FakeFirebaseFirestore();
    final doc =
        fs.collection('users').doc('u1').collection('profile').doc('main');
    await doc.set({'ayma_image_model': ''});

    await tester.pumpWidget(_host(ImageModelSelectorControl(
        api: _api(current: '', extraXai: true), firestore: fs, uid: 'u1')));
    await tester.pumpAndSettle();
    expect(find.text('Gemini (Google)'), findsOneWidget);

    await doc.set({'ayma_image_model': 'xai-direct'}, SetOptions(merge: true));
    await tester.pumpAndSettle();
    expect(find.text('Grok Imagine (xAI)'), findsOneWidget);
  });

  testWidgets('a genuinely-unreachable backend ends on error + Retry',
      (tester) async {
    final api = _ColdImageApi(down: true);
    await tester.pumpWidget(_host(ImageModelSelectorControl(api: api)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-model-selector-error')),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    api.down = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-model-selector-error')),
        findsNothing);
    expect(find.text('Gemini (Google)'), findsOneWidget);
    expect(find.byType(AymaWingLoader), findsNothing);
  });

  for (final (name, make) in [
    ('light', () => AymaTheme.light),
    ('dark', () => AymaTheme.dark),
  ]) {
    testWidgets(
        'dropdown container border color equals boundary and clears 3:1 on bg/bgElev/bgCard ($name)',
        (tester) async {
      await tester.pumpWidget(
          _host(ImageModelSelectorControl(api: _api()), make()));
      await tester.pumpAndSettle();

      final ac = tester.element(find.byType(ImageModelSelectorControl)).ac;
      final container = tester.widget<Container>(find
          .ancestor(
              of: find.byKey(const ValueKey('image-model-dropdown')),
              matching: find.byType(Container))
          .first);
      final border = (container.decoration as BoxDecoration).border as Border;
      expect(border.top.color, ac.boundary,
          reason: 'dropdown container border is boundary ($name)');
      for (final (label, surface) in [
        ('bg', ac.bg),
        ('bgElev', ac.bgElev),
        ('bgCard', ac.bgCard),
      ]) {
        final ratio = AymaColors.contrastRatio(border.top.color, surface);
        expect(ratio, greaterThanOrEqualTo(3.0),
            reason: 'image-model dropdown border vs $label = $ratio in $name');
      }
    });
  }
}

/// Drives `/image-model/preference` at the logical level so a test can force a
/// genuinely-down backend deterministically.
class _ColdImageApi extends ApiClient {
  _ColdImageApi({required this.down})
      : super(
          httpClient: MockClient((req) async => http.Response(
              jsonEncode({'ok': true}), 200,
              headers: const {'content-type': 'application/json'})),
          auth: MockFirebaseAuth(signedIn: true),
        );

  bool down;

  @override
  Future<ImageModelCatalog> imageModelPreference({Duration? timeout}) async {
    if (down) {
      throw ApiException('Request timed out — please try again.',
          statusCode: 503);
    }
    return ImageModelCatalog.fromMap(_catalog());
  }
}
