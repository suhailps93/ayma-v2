import 'dart:convert';

import 'package:ayma_flutter/screens/appearance_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _api(Map<String, dynamic> body, {int status = 200}) {
  final mockHttp = MockClient((request) async {
    if (request.url.path.startsWith('/appearance/report/')) {
      return http.Response(jsonEncode(body), status,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

/// Like [_api] but also serves `POST /appearance/finding/correct` — every
/// request it receives is captured in [corrections], and [reply] fn decides
/// what to send back for each `finding_id`.
ApiClient _apiWithCorrection(
  Map<String, dynamic> body,
  List<Map<String, dynamic>> corrections, {
  Map<String, dynamic> Function(Map<String, dynamic> req)? reply,
}) {
  final mockHttp = MockClient((request) async {
    if (request.url.path.startsWith('/appearance/report/')) {
      return http.Response(jsonEncode(body), 200,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    if (request.url.path == '/appearance/finding/correct') {
      final req = jsonDecode(request.body) as Map<String, dynamic>;
      corrections.add(req);
      final resp = reply?.call(req) ??
          {'ok': true, 'finding_id': req['finding_id'], 'value': 'blue',
           'reply': 'Got it — updated.'};
      return http.Response(jsonEncode(resp), 200,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

Map<String, dynamic> _face() => {
      'usable': true,
      'overall_score': 7.1,
      'verdict': 'Above average',
      'verdict_note': 'Strong eyes.',
      'features': [
        {'name': 'eyes', 'score': 8.0, 'note': 'Well spaced.'},
      ],
      'quick_facts': {'face_shape': 'oval'},
      'strengths': ['Expressive eyes'],
      'improvements': ['Even skin texture'],
      'recommendations': [
        {'category': 'skincare', 'text': 'Nightly retinoid.'},
      ],
    };

Map<String, dynamic> _body() => {
      'usable': true,
      'overall_score': 6.4,
      'verdict': 'Average',
      'verdict_note': '',
      'features': <dynamic>[],
      'quick_facts': <String, dynamic>{},
      'strengths': <dynamic>[],
      'improvements': ['Posture'],
      'recommendations': <dynamic>[],
    };

void main() {
  testWidgets('renders all three sections, plus the headline score',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api({
      'id': 'a1',
      'created_at': '2026-02-03T10:00:00',
      'photo_count': 4,
      'attributes': {
        'summary': 'Physical profile — hair: black (from photos).',
        'record': {
          'build': {
            'value': 'athletic',
            'source': 'stated',
            'confidence': 'high',
          },
          'hair_color': {
            'value': 'black',
            'source': 'photo',
            'confidence': 'high',
          },
        },
      },
      'face': _face(),
      'body': _body(),
      // The real backend (`_compute_score` in appearance.py) sends a terse
      // machine tag here, NOT a sentence — the widget is responsible for
      // turning it into display copy. Using the real tag (not a fabricated
      // sentence fixture) is what catches a regression like the "none"
      // literal-text bug this test guards against.
      'score': {'value': 6.75, 'basis': 'face+body'},
    });

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a1', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsWidgets); // app bar + header
    expect(find.text('ATTRIBUTES'), findsOneWidget);
    expect(find.text('FACE'), findsOneWidget);
    expect(find.text('PHYSIQUE'), findsOneWidget);
    expect(find.text('FROM YOUR ANSWERS'), findsOneWidget);
    expect(find.text('READ FROM YOUR PHOTOS'), findsOneWidget);
    expect(find.text('Athletic'), findsOneWidget);
    expect(find.textContaining('FACIAL BEAUTY REPORT'), findsOneWidget);
    // Score banner: numeric score plus the translated (not raw-tag) copy.
    expect(find.text('6.8'), findsOneWidget);
    expect(find.text('Based on your face and physique photos.'),
        findsOneWidget);
    expect(find.text('face+body'), findsNothing);
  });

  testWidgets(
      'score banner never shows the raw "none" basis tag — shows an '
      'explanatory placeholder instead', (tester) async {
    final api = _api({
      'id': 'a0',
      'photo_count': 0,
      'attributes': {'record': <String, dynamic>{}},
      'face': {'status': 'needs_face_photo'},
      'body': {'status': 'needs_body_photo'},
      // This is exactly what `_compute_score` persists when neither face nor
      // body has a computed score yet (§ founder report: the score banner
      // showed the literal word "none" next to the bar-chart icon).
      'score': {'value': null, 'basis': 'none'},
    });

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a0', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('none'), findsNothing);
    expect(
      find.text('Add a clear face or full-length photo to get your score.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.bar_chart_rounded), findsOneWidget);
  });

  testWidgets('renders every contributing photo when the report has them',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api({
      'id': 'a3',
      'created_at': '2026-02-03T10:00:00',
      'photo_count': 3,
      'attributes': {
        'summary': 'Physical profile — hair: black (from photos).',
        'record': {
          'hair_color': {
            'value': 'black', 'source': 'photo', 'confidence': 'high',
          },
        },
        'source_photos': ['uploads/me/a.jpg', 'uploads/me/b.jpg'],
      },
      'face': {..._face(), 'source_photos': ['uploads/me/face.jpg']},
      'body': {..._body(), 'source_photos': ['uploads/me/body.jpg']},
    });

    final resolved = <String>[];
    Future<String?> fakeResolver(String path) async {
      resolved.add(path);
      return 'https://cdn.example.com/$path';
    }

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(
        reportId: 'a3',
        apiClient: api,
        photoUrlResolver: fakeResolver,
      ),
    ));
    await tester.pump(); // let the report + photo-url futures resolve
    await tester.pump();
    await tester.pump(); // real Image.network calls never settle; don't wait

    // Every source photo across all three parts was resolved.
    expect(resolved, containsAll(<String>[
      'uploads/me/a.jpg', 'uploads/me/b.jpg',
      'uploads/me/face.jpg', 'uploads/me/body.jpg',
    ]));
    // The attributes photo strip shows a labelled thumbnail row.
    expect(find.text('USED FOR ATTRIBUTES'), findsOneWidget);
    // Face (1) + body (1) + attributes (2) contributing photos rendered.
    expect(find.byType(Image), findsNWidgets(4));
  });

  testWidgets('shows the missing-photo stubs for gated sections', (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api({
      'id': 'a2',
      'created_at': '2026-02-03T10:00:00',
      'photo_count': 1,
      'attributes': {
        'summary': 'Physical profile — eyes: brown (from photos).',
        'record': {
          'eye_color': {
            'value': 'brown',
            'source': 'photo',
            'confidence': 'medium',
          },
        },
      },
      'face': _face(),
      'body': {'status': 'needs_body_photo'},
    });

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a2', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('PHYSIQUE'), findsOneWidget);
    expect(find.textContaining('Add a full-length photo to include this'),
        findsOneWidget);
    expect(find.text('Add a full-length photo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a retry message when the report fails to load',
      (tester) async {
    final api = _api(const {}, status: 404);
    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'nope', apiClient: api),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't load that report"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  Map<String, dynamic> reportWithAttributes() => {
        'id': 'a4',
        'created_at': '2026-02-03T10:00:00',
        'photo_count': 2,
        'attributes': {
          'summary': 'Physical profile — eyes: brown (from photos).',
          'record': {
            'eye_color': {
              'value': 'brown', 'source': 'photo', 'confidence': 'medium',
            },
          },
        },
        'face': {'status': 'needs_face_photo'},
        'body': {'status': 'needs_body_photo'},
      };

  testWidgets(
      'tapping an attribute opens the tap-a-claim correction sheet; sending '
      'moves it to FROM YOUR ANSWERS', (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final corrections = <Map<String, dynamic>>[];
    final api = _apiWithCorrection(
      reportWithAttributes(), corrections,
      reply: (req) => {
        'ok': true, 'finding_id': req['finding_id'], 'value': 'blue',
        'reply': "Updated your eyes to blue.",
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a4', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('READ FROM YOUR PHOTOS'), findsOneWidget);
    expect(find.text('Brown'), findsOneWidget);

    await tester.tap(find.text('Brown'));
    await tester.pumpAndSettle();

    // The correction sheet opens with the claim quoted.
    expect(find.text('Correct with Ayma'), findsOneWidget);
    expect(find.text('Brown'), findsWidgets); // quoted claim + (soon) the row

    await tester.enterText(find.byType(TextField), "they're actually blue");
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(corrections, [
      {'finding_id': 'eye_color', 'message': "they're actually blue"},
    ]);
    // Ayma's reply is shown inside the sheet.
    expect(find.text('Updated your eyes to blue.'), findsOneWidget);

    await tester.tapAt(const Offset(20, 20)); // dismiss the sheet
    await tester.pumpAndSettle();

    // ...and the row now shows under FROM YOUR ANSWERS as the new value.
    expect(find.text('FROM YOUR ANSWERS'), findsOneWidget);
    expect(find.text('Blue'), findsOneWidget);
    expect(find.text('Brown'), findsNothing);
  });

  testWidgets('a capped correction shows the reload pill and does not update '
      'the value', (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final corrections = <Map<String, dynamic>>[];
    final api = _apiWithCorrection(
      reportWithAttributes(), corrections,
      reply: (req) => {'usage_capped': true},
    );

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a4', apiClient: api),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Brown'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'blue please');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(find.text('Reload credits'), findsOneWidget);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // Value unchanged — still under READ FROM YOUR PHOTOS.
    expect(find.text('READ FROM YOUR PHOTOS'), findsOneWidget);
    expect(find.text('Brown'), findsOneWidget);
  });

  testWidgets('tapping the face score header opens the correction sheet for '
      "face and updates the shown note", (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final corrections = <Map<String, dynamic>>[];
    final api = _apiWithCorrection(
      {
        'id': 'a5',
        'photo_count': 1,
        'attributes': {'record': <String, dynamic>{}},
        'face': _face(),
        'body': {'status': 'needs_body_photo'},
      },
      corrections,
      reply: (req) => {
        'ok': true, 'finding_id': 'face', 'value': 'Warm, genuine smile.',
        'reply': 'Updated the note.',
      },
    );

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a5', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Tap to correct'), findsWidgets);
    // Tap the score header area (the "7.1" score inside FaceReportView).
    await tester.tap(find.text('7.1'));
    await tester.pumpAndSettle();

    expect(find.text('Correct with Ayma'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'I have a warm smile');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    expect(corrections, [
      {'finding_id': 'face', 'message': 'I have a warm smile'},
    ]);
    expect(find.text('Updated the note.'), findsOneWidget);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.text('Warm, genuine smile.'), findsOneWidget);
  });
}
