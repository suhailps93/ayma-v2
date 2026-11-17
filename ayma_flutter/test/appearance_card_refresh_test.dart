// NOTE 243 Leg 1 regression: re-running the Appearance report with a photo
// DESELECTED from an axis must refresh the shareable card. On device the card
// stayed stuck on the previous run — old photos AND old scores — even after a
// force-stop + relaunch, while the rest of the report updated. The screen
// paints the last cached report instantly (stale-while-revalidate) and then
// fetches fresh; this proves the card rebuilds from the FRESH report when it
// lands instead of leaving the cache-restored one on screen.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/screens/appearance_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/report_cache.dart';
import 'package:ayma_flutter/services/report_card_share.dart';
import 'package:ayma_flutter/services/report_events.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final Uint8List _png = File('test/fixtures/tiny.png').readAsBytesSync();

Future<ui.Image> _decoded(WidgetTester tester) async =>
    (await tester.runAsync(() => decodeImageFromList(_png)))!;

/// An ImageProvider whose decode never completes — models a brand-new Storage
/// photo that is still downloading when a re-run lands, so a test can prove
/// the card no longer waits on the whole pool before showing the fresh run.
class _PendingImage extends ImageProvider<_PendingImage> {
  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_PendingImage>(this);

  @override
  ImageStreamCompleter loadImage(_PendingImage key, ImageDecoderCallback decode) =>
      _NeverCompleter();
}

class _NeverCompleter extends ImageStreamCompleter {}

/// A minimal Appearance report that yields a share card: a Face and a Body
/// score plus one selected photo per axis. [bodyPhotoId]/[bodyPhotoUrl] model
/// the axis photo that a re-run can change (the deselected pottery shot in the
/// stale run, the kept body shot in the fresh run).
Map<String, dynamic> _report({
  required num faceScore,
  required num bodyScore,
  required String bodyPhotoId,
  required String bodyPhotoUrl,
  required String createdAt,
}) => {
      'title': 'Appearance',
      'sections': [
        {
          'heading': 'Face',
          'blocks': [
            {
              'block_id': 'face',
              'type': 'stat',
              'editable': true,
              'label': 'Face',
              'value': faceScore,
              'basis': 'Above average',
            },
            {
              'block_id': 'face:photo',
              'type': 'photo',
              'editable': true,
              'url': 'face.jpg',
              'photo_id': 'seed_face',
            },
          ],
        },
        {
          'heading': 'Body',
          'blocks': [
            {
              'block_id': 'body',
              'type': 'stat',
              'editable': true,
              'label': 'Body',
              'value': bodyScore,
              'basis': 'Average',
            },
            {
              'block_id': 'body:photo',
              'type': 'photo',
              'editable': true,
              'url': bodyPhotoUrl,
              'photo_id': bodyPhotoId,
            },
          ],
        },
      ],
      'meta': {
        'owner_uid': 'u1',
        'viewer_can_edit': true,
        'created_at': createdAt,
        'updated_at': createdAt,
      },
    };

ApiClient _api(Map<String, dynamic> report) => ApiClient(
      httpClient: MockClient(
        (req) async => http.Response(
          jsonEncode(report),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
      auth: MockFirebaseAuth(signedIn: true),
    );

/// An ApiClient whose `/report/appearance/...` response is whatever
/// [current] points at when the request arrives — lets a test flip the
/// server's answer mid-session (a background re-run landing) before firing a
/// [ReportEvents] completion.
ApiClient _mutableApi(ValueGetter<Map<String, dynamic>> current) => ApiClient(
      httpClient: MockClient(
        (req) async => http.Response(
          jsonEncode(current()),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
      auth: MockFirebaseAuth(signedIn: true),
    );

void main() {
  // CachedNetworkImage (the full report's photo rows) reaches for
  // path_provider; stub it so it never throws a MissingPluginException.
  late Directory tmpDir;
  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('appr_refresh');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => tmpDir.path);
    ReportCache.instance.resetForTest();
  });
  tearDown(() {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    ReportCache.instance.resetForTest();
    tmpDir.deleteSync(recursive: true);
  });

  testWidgets(
      'the share card rebuilds from the FRESH run after a stale cache restore '
      '(deselected photo + new scores win; the old run never lingers)',
      (tester) async {
    // The last run, cached on this device: scores 7.5 / 6.1.
    SharedPreferences.setMockInitialValues({
      'report_cache:u1:appearance:u1': jsonEncode(_report(
        faceScore: 7.5,
        bodyScore: 6.1,
        bodyPhotoId: 'seed_candid',
        bodyPhotoUrl: 'pottery.jpg',
        createdAt: '2026-11-17T02:00:00Z',
      )),
    });

    final img = await _decoded(tester);

    // The fresh re-run the server now returns: pottery deselected from Body,
    // scores dropped to 7.4 / 5.6.
    final api = _api(_report(
      faceScore: 7.4,
      bodyScore: 5.6,
      bodyPhotoId: 'seed_body',
      bodyPhotoUrl: 'body.jpg',
      createdAt: '2026-11-17T02:42:45Z',
    ));

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(
        reportId: 'current',
        myUid: 'u1',
        apiClient: api,
        imageFor: (_) => DecodedImage(img),
      ),
    ));
    // Let the cache restore paint, then the fresh fetch land and swap in.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The card shows the FRESH run's scores, and the stale run's are gone.
    expect(find.text('7.4'), findsOneWidget);
    expect(find.text('5.6'), findsOneWidget);
    expect(find.text('7.5'), findsNothing);
    expect(find.text('6.1'), findsNothing);
  });

  testWidgets(
      'Re-run on the OPEN screen refreshes the card when the run completes '
      '(the exact device path: a background re-run, not a fresh open)',
      (tester) async {
    addTearDown(() => ReportEvents.instance.stopped('appearance'));

    final img = await _decoded(tester);

    // The screen opens on the current run (7.5 / 6.1, pottery in Body).
    var served = _report(
      faceScore: 7.5,
      bodyScore: 6.1,
      bodyPhotoId: 'seed_candid',
      bodyPhotoUrl: 'pottery.jpg',
      createdAt: '2026-11-17T02:00:00Z',
    );
    final api = _mutableApi(() => served);

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(
        reportId: 'current',
        myUid: 'u1',
        apiClient: api,
        imageFor: (_) => DecodedImage(img),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('7.5'), findsOneWidget);

    // The user re-runs with the pottery shot deselected. The run completes in
    // the background: the server now returns 7.4 / 5.6 and a kept body shot,
    // and a ReportEvents completion tells the open screen to reload.
    served = _report(
      faceScore: 7.4,
      bodyScore: 5.6,
      bodyPhotoId: 'seed_body',
      bodyPhotoUrl: 'body.jpg',
      createdAt: '2026-11-17T02:42:45Z',
    );
    // Mirror report_run_flows.dart's success sequence exactly: started, then
    // completed (bumps the revision an open report reloads on) + stopped.
    ReportEvents.instance.started('appearance');
    await tester.pump();
    ReportEvents.instance.completed('appearance');
    ReportEvents.instance.stopped('appearance');
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The card reflects the completed re-run, not the run it opened on.
    expect(find.text('7.4'), findsOneWidget);
    expect(find.text('5.6'), findsOneWidget);
    expect(find.text('7.5'), findsNothing);
    expect(find.text('6.1'), findsNothing);
  });

  testWidgets(
      "a fresh run's NEW photo that is still downloading must not hold the "
      'whole card on the previous run (scores swap the moment the report lands)',
      (tester) async {
    addTearDown(() => ReportEvents.instance.stopped('appearance'));

    final img = await _decoded(tester);
    // The kept face photo decodes instantly; the re-run's new body photo is
    // still downloading (never decodes during the test window).
    ImageProvider imageFor(String url) =>
        url == 'body.jpg' ? _PendingImage() : DecodedImage(img);

    var served = _report(
      faceScore: 7.5,
      bodyScore: 6.1,
      bodyPhotoId: 'seed_candid',
      bodyPhotoUrl: 'pottery.jpg',
      createdAt: '2026-11-17T02:00:00Z',
    );
    final api = _mutableApi(() => served);

    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(
        reportId: 'current',
        myUid: 'u1',
        apiClient: api,
        imageFor: imageFor,
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('7.5'), findsOneWidget);

    // Re-run completes: scores 7.4 / 5.6, pottery deselected, a new body shot
    // (body.jpg) whose download has not finished.
    served = _report(
      faceScore: 7.4,
      bodyScore: 5.6,
      bodyPhotoId: 'seed_body',
      bodyPhotoUrl: 'body.jpg',
      createdAt: '2026-11-17T02:42:45Z',
    );
    ReportEvents.instance.started('appearance');
    await tester.pump();
    ReportEvents.instance.completed('appearance');
    ReportEvents.instance.stopped('appearance');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Even though the new body photo is still downloading, the card already
    // shows the FRESH run's scores — never the previous run's.
    expect(find.text('7.4'), findsOneWidget);
    expect(find.text('7.5'), findsNothing);
    expect(find.text('6.1'), findsNothing);

    // Let the still-pending photo decode hit its timeout so no Timer outlives
    // the test (the card is unaffected — it already shows the fresh run).
    await tester.pump(const Duration(seconds: 20));
    expect(find.text('7.4'), findsOneWidget);
  });

  testWidgets(
      'NOTE 250 Leg 1: re-run with a new report id (Vo2iuT4) repaints '
      'the card with fresh scores, never stale ones',
      (tester) async {
    const uid = 'demo-test1';
    final img = await _decoded(tester);

    // Network request gate: holds every network response until the fresh
    // run lands, so we can assert nothing stale paints first. (P2: the card
    // loads via an uncached getReport fired on the tree onLoaded — the old
    // report_cache first-paint is gone by design, and nothing writes that
    // cache key on this screen anymore.)
    final netGate = Completer<Map<String, dynamic>>();
    final api = ApiClient(
      httpClient: MockClient((req) async {
        final payload = await netGate.future;
        return http.Response(
          jsonEncode(payload),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
      auth: MockFirebaseAuth(signedIn: true),
    );

    // Screen opened with the new run id Vo2iuT4
    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(
        reportId: 'Vo2iuT4',
        myUid: uid,
        apiClient: api,
        imageFor: (_) => DecodedImage(img),
      ),
    ));

    // Nothing paints while the fresh fetch is gated — no stale scores:
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('7.5'), findsNothing);
    expect(find.text('7.8'), findsNothing);

    // Fresh run Vo2iuT4 from 11:33:27Z lands: scores 7.8 / 6.2
    netGate.complete(_report(
      faceScore: 7.8,
      bodyScore: 6.2,
      bodyPhotoId: 'seed_body',
      bodyPhotoUrl: 'body.jpg',
      createdAt: '2026-11-17T11:33:27Z',
    ));

    // Let the fresh fetch land and swap in:
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Card repaints with fresh scores:
    expect(find.text('7.8'), findsOneWidget);
    expect(find.text('6.2'), findsOneWidget);
    expect(find.text('7.5'), findsNothing);
    expect(find.text('6'), findsNothing);
  });
}
