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

const _schemaFields = [
  {
    'field': 'eye_color',
    'type': 'enum',
    'values': ['brown', 'blue', 'green', 'hazel', 'grey', 'other'],
  },
  {'field': 'height_estimate_cm', 'type': 'int'},
  {'field': 'race_ethnicity', 'type': 'string'},
];

/// Like [_api] but also serves `/physical-attributes/schema` and records
/// every `/physical-attributes/correct` request it receives in [corrections]
/// so a test can assert what was sent, and echoes back a coerced value.
ApiClient _apiWithEditing(
  Map<String, dynamic> body,
  List<Map<String, dynamic>> corrections,
) {
  final mockHttp = MockClient((request) async {
    if (request.url.path.startsWith('/appearance/report/')) {
      return http.Response(jsonEncode(body), 200,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    if (request.url.path == '/physical-attributes/schema') {
      return http.Response(jsonEncode({'fields': _schemaFields}), 200,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    if (request.url.path == '/physical-attributes/correct') {
      final req = jsonDecode(request.body) as Map<String, dynamic>;
      final sent = (req['corrections'] as List).cast<Map<String, dynamic>>();
      corrections.addAll(sent);
      final fields = <String, dynamic>{
        for (final c in sent) c['field'] as String: c['value'],
      };
      return http.Response(jsonEncode({'ok': true, 'fields': fields}), 200,
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

void main() {
  testWidgets('renders all three sections when the report is complete',
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
      'body': {
        'usable': true,
        'overall_score': 6.4,
        'verdict': 'Average',
        'verdict_note': '',
        'features': <dynamic>[],
        'quick_facts': <String, dynamic>{},
        'strengths': <dynamic>[],
        'improvements': ['Posture'],
        'recommendations': <dynamic>[],
      },
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
      'body': {
        'usable': true,
        'overall_score': 6.4,
        'verdict': 'Average',
        'verdict_note': '',
        'features': <dynamic>[],
        'quick_facts': <String, dynamic>{},
        'strengths': <dynamic>[],
        'improvements': ['Posture'],
        'recommendations': <dynamic>[],
        'source_photos': ['uploads/me/body.jpg'],
      },
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
    // No source_photos on this (pre-existing-shape) report — no photo strip,
    // no broken-image icon, and no crash.
    expect(find.byType(Image), findsNothing);
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

  Map<String, dynamic> reportWithEditableFields() => {
        'id': 'a4',
        'created_at': '2026-02-03T10:00:00',
        'photo_count': 2,
        'attributes': {
          'summary': 'Physical profile — eyes: brown (from photos).',
          'record': {
            'eye_color': {
              'value': 'brown', 'source': 'photo', 'confidence': 'medium',
            },
            'height_estimate_cm': {
              'value': 170, 'source': 'photo', 'confidence': 'low',
            },
            'race_ethnicity': {
              'value': 'South Asian', 'source': 'photo', 'confidence': 'low',
            },
          },
        },
        'face': {'status': 'needs_face_photo'},
        'body': {'status': 'needs_body_photo'},
      };

  testWidgets('tapping an enum row opens a picker; saving moves it to '
      'FROM YOUR ANSWERS', (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final corrections = <Map<String, dynamic>>[];
    final api = _apiWithEditing(reportWithEditableFields(), corrections);

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a4', apiClient: api),
    ));
    await tester.pumpAndSettle();

    // Starts under READ FROM YOUR PHOTOS, apparent value capitalised.
    expect(find.text('READ FROM YOUR PHOTOS'), findsOneWidget);
    expect(find.text('Brown'), findsOneWidget);

    await tester.tap(find.text('Brown'));
    await tester.pumpAndSettle();

    // The enum picker bottom sheet lists the schema's values.
    expect(find.text('Blue'), findsOneWidget);
    expect(find.text('Green'), findsOneWidget);

    await tester.tap(find.text('Blue'));
    await tester.pumpAndSettle();

    // The correction was sent...
    expect(
        corrections.any((c) => c['field'] == 'eye_color' && c['value'] == 'blue'),
        isTrue);
    // ...and the row now shows under FROM YOUR ANSWERS as the new value.
    expect(find.text('FROM YOUR ANSWERS'), findsOneWidget);
    expect(find.text('Blue'), findsOneWidget);
    expect(find.text('Brown'), findsNothing);
  });

  testWidgets('tapping a numeric row opens a number field; saving updates '
      'the displayed value', (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final corrections = <Map<String, dynamic>>[];
    final api = _apiWithEditing(reportWithEditableFields(), corrections);

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a4', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('~170 cm'), findsOneWidget);
    await tester.tap(find.text('~170 cm'));
    await tester.pumpAndSettle();

    // A dialog with a text field, not a bottom-sheet picker.
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), '182');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
        corrections.any(
            (c) => c['field'] == 'height_estimate_cm' && c['value'] == 182),
        isTrue);
    expect(find.text('~182 cm'), findsOneWidget);
  });

  testWidgets('tapping a free-text row opens a text field; saving updates '
      'the displayed value', (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final corrections = <Map<String, dynamic>>[];
    final api = _apiWithEditing(reportWithEditableFields(), corrections);

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a4', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('South Asian'), findsOneWidget);
    await tester.tap(find.text('South Asian'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Mixed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
        corrections
            .any((c) => c['field'] == 'race_ethnicity' && c['value'] == 'Mixed'),
        isTrue);
    expect(find.text('Mixed'), findsOneWidget);
  });
}
