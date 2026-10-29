// The shareable Appearance report card: what it may show (photos capped at
// four, both scores always, positive findings only), long-text safety, the
// 1080x1920 PNG export, and the single native-share hand-off.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/models/appearance_card.dart';
import 'package:ayma_flutter/models/living_report.dart';
import 'package:ayma_flutter/screens/appearance_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/report_card_share.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/appearance_report_card.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:share_plus/share_plus.dart';

final Uint8List _png = File('test/fixtures/tiny.png').readAsBytesSync();

/// Serves one local fixture file for any URL, so the full report's photo
/// thumbnails (rendered through [AymaPhoto] → [CachedNetworkImage]) run their
/// real decode pipeline with no sqflite cache database and no network — the
/// screen tests mount the whole report, so without this the cache manager
/// would reach for a database that `databaseFactory` never initialises under
/// test and leave its download future pending at teardown.
class _FakeCacheManager implements BaseCacheManager {
  _FakeCacheManager(File ioFile)
    : file = const LocalFileSystem().file(ioFile.path);

  // flutter_cache_manager's API speaks package:file's File type.
  final fs.File file;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    yield FileInfo(
      file,
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }

  @override
  Future<fs.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async => file;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Map<String, dynamic> _b(String id, String type, [Map<String, dynamic>? f]) => {
  'block_id': id,
  'type': type,
  'editable': true,
  ...?f,
};

/// An Appearance report shaped exactly like `report_adapters.appearance_blocks`.
Map<String, dynamic> _report({
  bool bodyScore = true,
  int attrPhotos = 4,
  String faceStrength = 'Full eyebrows',
}) => {
  'title': 'Appearance',
  'sections': [
    {
      'heading': 'Attributes',
      'blocks': [
        _b('attr:eye_color', 'attribute', {'label': 'Eyes', 'value': 'Brown'}),
        _b('attr:photos', 'photo_grid', {
          'photos': [
            for (var i = 0; i < attrPhotos; i++)
              {'url': 'https://x/attr$i.jpg'},
            {'url': 'https://x/face.jpg'},
          ],
        }),
      ],
    },
    {
      'heading': 'Face',
      'blocks': [
        _b('face', 'stat', {
          'label': 'Above average',
          'value': 6.3,
          'basis': 'Above average',
        }),
        _b('face:note:sent:0', 'text', {'text': 'A balanced face.'}),
        _b('face:strength:0', 'fact', {
          'text': faceStrength,
          'tag': 'strength',
        }),
        _b('face:strength:1', 'fact', {
          'text': 'Expressive dark eyes',
          'tag': 'strength',
        }),
        _b('face:strength:2', 'fact', {
          'text': 'Thick, textured hair',
          'tag': 'strength',
        }),
        _b('face:improvement:0', 'fact', {
          'text': 'Under-eye shadows',
          'tag': 'improvement',
        }),
        _b('face:reco:0', 'fact', {
          'text': 'Trim the beard along the jaw.',
          'tag': 'beard_grooming',
        }),
        _b('face:quick:worst_feature', 'attribute', {
          'label': 'Worst feature',
          'value': 'Under-eyes',
        }),
        _b('face:photo', 'photo', {'url': 'https://x/face.jpg'}),
      ],
    },
    {
      'heading': 'Body',
      'blocks': [
        if (bodyScore)
          _b('body', 'stat', {
            'label': 'Below average',
            'value': 4.2,
            'basis': 'Below average',
          }),
        _b('body:strength:0', 'fact', {
          'text': 'Broad shoulders',
          'tag': 'strength',
        }),
        _b('body:strength:1', 'fact', {
          'text': 'Low body fat around 18%',
          'tag': 'strength',
        }),
        _b('body:improvement:0', 'fact', {
          'text': 'Narrow chest',
          'tag': 'improvement',
        }),
        _b('body:reco:0', 'fact', {
          'text': 'Progressive resistance training.',
          'tag': 'training',
        }),
        _b('body:quick:estimated_body_fat_range', 'attribute', {
          'label': 'Estimated body fat range',
          'value': '20-24%',
        }),
        _b('body:photo', 'photo', {'url': 'https://x/body.jpg'}),
      ],
    },
  ],
  'meta': {'owner_uid': 'u1', 'viewer_can_edit': true},
};

LivingReport _living(Map<String, dynamic> m) => LivingReport.fromMap(m);

AppearanceCardData _data({List<String>? standOuts}) {
  final d = AppearanceCardData.fromReport(_living(_report()))!;
  if (standOuts == null) return d;
  return AppearanceCardData(
    pool: d.pool,
    hidden: d.hidden,
    faceScore: d.faceScore,
    faceVerdict: d.faceVerdict,
    bodyScore: d.bodyScore,
    bodyVerdict: d.bodyVerdict,
    standOuts: standOuts,
    nextSteps: d.nextSteps,
  );
}

List<(ImageProvider, String)> _photos(int n) => [
  for (var i = 0; i < n; i++) (MemoryImage(_png), 'photo $i'),
];

/// The polaroid photos only (each carries a 'photo N' semantic label), never
/// the two logo marks — so photo-count assertions ignore the brand logo.
final Finder _photoImages = find.byWidgetPredicate(
  (w) => w is Image && (w.semanticLabel?.startsWith('photo') ?? false),
);

/// Photos on the real [AppearanceReportScreen] — their labels come from the
/// card data ('Your face photo', 'Your body photo', 'Your photo'), so match
/// that instead, again ignoring the two logo marks.
final Finder _screenPhotoImages = find.byWidgetPredicate(
  (w) => w is Image && (w.semanticLabel?.startsWith('Your') ?? false),
);

Widget _card(AppearanceCardData d, {String name = 'Suhail', int photos = 4}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: AppearanceReportCard(
            data: d,
            name: name,
            accent: AymaColors.accent,
            photos: _photos(photos),
          ),
        ),
      ),
    );

const _forbidden = [
  'Under-eye shadows',
  'Narrow chest',
  'Trim the beard',
  'Progressive resistance',
  'Under-eyes',
  '20-24%',
  'body fat',
  '18%',
  'A balanced face',
];

class _Profile extends ProfileService {
  _Profile() : super(auth: MockFirebaseAuth());
  @override
  Future<ProfileData?> readProfile() async =>
      ProfileData.fromMap({'first_name': 'Suhail', 'name': 'Suhail P'});
}

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

Future<ui.Image> _decoded(WidgetTester tester) async =>
    (await tester.runAsync(() => decodeImageFromList(_png)))!;

/// Width/height from a PNG's IHDR chunk.
(int, int) _pngSize(Uint8List b) {
  final d = ByteData.sublistView(b);
  return (d.getUint32(16), d.getUint32(20));
}

void main() {
  // The screen tests mount the whole AppearanceReportScreen, whose embedded
  // full report draws its photo thumbnails through AymaPhoto/CachedNetworkImage.
  // Point that at a fake cache manager serving the checked-in fixture so no
  // sqflite cache database is opened and no download future is left pending.
  setUp(() {
    AymaPhoto.debugCacheManager = _FakeCacheManager(
      File('test/fixtures/tiny.png'),
    );
  });
  tearDown(() => AymaPhoto.debugCacheManager = null);

  group('AppearanceCardData', () {
    test('caps photos at four, face photo first, no duplicates', () {
      final d = AppearanceCardData.fromReport(_living(_report(attrPhotos: 6)))!;
      expect(d.photoUrls, hasLength(AppearanceCardData.maxPhotos));
      expect(d.photoUrls.first, 'https://x/face.jpg');
      expect(d.photoUrls[1], 'https://x/body.jpg');
      expect(d.photoUrls.toSet(), hasLength(4));
      expect(d.photoLabels.first, 'Your face photo');
    });

    test('fewer photos: only what exists', () {
      final d = AppearanceCardData.fromReport(_living(_report(attrPhotos: 0)))!;
      expect(d.photoUrls, ['https://x/face.jpg', 'https://x/body.jpg']);
    });

    test('scores and verdicts come from the report', () {
      final d = _data();
      expect((d.faceScore, d.bodyScore), ('6.3', '4.2'));
      expect(
        (d.faceVerdict, d.bodyVerdict),
        ('Above average', 'Below average'),
      );
    });

    test('stands out: strengths only, never sensitive, at most four', () {
      final d = _data();
      expect(d.standOuts, [
        'Full eyebrows',
        'Broad shoulders',
        'Expressive dark eyes',
        'Thick, textured hair',
      ]);
      for (final f in _forbidden) {
        expect(d.standOuts.join(' '), isNot(contains(f)));
      }
    });

    test('next steps are the recommendations, kept off the card', () {
      expect(_data().nextSteps, [
        ('Grooming', 'Trim the beard along the jaw.'),
        ('Training', 'Progressive resistance training.'),
      ]);
    });

    test('no card when a score is missing', () {
      expect(
        AppearanceCardData.fromReport(_living(_report(bodyScore: false))),
        isNull,
      );
    });
  });

  group('AppearanceReportCard', () {
    testWidgets('shows both scores, four photos, positive findings only', (
      tester,
    ) async {
      await tester.pumpWidget(_card(_data(), photos: 4));
      expect(find.text('6.3'), findsOneWidget);
      expect(find.text('4.2'), findsOneWidget);
      expect(find.text('FACE'), findsOneWidget);
      expect(find.text('BODY'), findsOneWidget);
      expect(_photoImages, findsNWidgets(4));
      expect(find.text('Full eyebrows'), findsOneWidget);
      expect(find.textContaining('Face: above average'), findsOneWidget);
      expect(find.textContaining('Get your report on'), findsOneWidget);
      expect(
        find.text('AI estimates from photos. An opinion, not a fact.'),
        findsOneWidget,
      );
      for (final f in _forbidden) {
        expect(find.textContaining(f), findsNothing, reason: f);
      }
      expect(find.bySemanticsLabel('photo 0'), findsOneWidget);
    });

    testWidgets('never more than four photo frames', (tester) async {
      await tester.pumpWidget(_card(_data(), photos: 6));
      expect(_photoImages, findsNWidgets(4));
    });

    testWidgets('fewer photos draw no empty frames', (tester) async {
      await tester.pumpWidget(_card(_data(), photos: 2));
      expect(_photoImages, findsNWidgets(2));
    });

    testWidgets('header and footer show the real Ayma logo asset', (
      tester,
    ) async {
      await tester.pumpWidget(_card(_data(), photos: 4));
      final logos = tester.widgetList<Image>(
        find.byKey(const ValueKey('reportCardLogo')),
      );
      expect(logos, hasLength(2));
      for (final img in logos) {
        expect(
          img.image,
          isA<AssetImage>().having(
            (a) => a.assetName,
            'assetName',
            AppearanceReportCard.logoAsset,
          ),
        );
      }
      expect(AppearanceReportCard.logoAsset, 'assets/icon/ayma_orb_ios.png');
    });

    testWidgets('long name and long findings ellipsize without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final long = 'Maximiliana-Alexandrina ' * 4;
      await tester.pumpWidget(
        _card(
          _data(
            standOuts: List.filled(
              4,
              'An unusually long positive finding ' * 3,
            ),
          ),
          name: long,
        ),
      );
      expect(tester.takeException(), isNull);
      final name = tester.widget<Text>(
        find.byKey(const ValueKey('reportCardName')),
      );
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(
        tester.getSize(find.byType(AppearanceReportCard)),
        AppearanceReportCard.size,
      );
    });

    test('accent text keeps AA contrast on the paper for any accent', () {
      for (final c in const [
        Color(0xFFFFE066),
        Color(0xFF7FFFD4),
        Color(0xFFFFFFFF),
        AymaColors.accent,
        Color(0xFF101010),
      ]) {
        final ink = AppearanceReportCard.inkAccent(c);
        expect(
          AppearanceReportCard.contrast(ink, const Color(0xFFF5EEE4)),
          greaterThanOrEqualTo(4.5),
          reason: '$c',
        );
      }
    });
  });

  testWidgets('PNG export is 1080x1920', (tester) async {
    late Uint8List png;
    await tester.runAsync(() async {
      final img = (await ReportCardShare.decode(MemoryImage(_png)))!;
      final photos = [
        for (var i = 0; i < 4; i++) (DecodedImage(img), 'photo $i'),
      ];
      png = await ReportCardShare.renderPng(
        AppearanceReportCard(
          data: _data(),
          name: 'Suhail',
          accent: AymaColors.accent,
          photos: photos,
        ),
        view: tester.view,
        logicalSize: AppearanceReportCard.size,
      );
    });
    expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    expect(_pngSize(png), (1080, 1920));
  });

  group('screen', () {
    testWidgets('card, Share, private next steps, then the full report', (
      tester,
    ) async {
      final img = await _decoded(tester);
      final shares = <String?>[];
      // Tapping Share decodes the logo under runAsync; the report below renders
      // its own network images through flutter_cache_manager, so stub the
      // path_provider channel it reaches for (it would otherwise throw a
      // MissingPluginException inside the runAsync zone).
      final tmpDir = Directory.systemTemp.createTempSync('appr_screen');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async => tmpDir.path);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, null));
      await tester.pumpWidget(
        MaterialApp(
          home: AppearanceReportScreen(
            reportId: 'current',
            myUid: 'u1',
            apiClient: _api(_report()),
            profileService: _Profile(),
            imageFor: (_) => DecodedImage(img),
            shareService: _CapturingShare(shares),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(AppearanceReportCard), findsOneWidget);
      expect(find.text('Suhail'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('^Your Appearance report card')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('GROOMING'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('What to do next'), findsOneWidget);
      expect(
        find.text('Only you see this. It is never part of the shared card.'),
        findsOneWidget,
      );
      expect(find.text('GROOMING'), findsOneWidget);
      // The full report is still below (attributes).
      await tester.scrollUntilVisible(
        find.text('Brown'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Brown'), findsOneWidget);
      // Recommendations live only in "What to do next", not the full report.
      expect(
        find.text('Trim the beard along the jaw.', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('Progressive resistance training.', skipOffstage: false),
        findsOneWidget,
      );
      // The old AppBar link-share action is gone.
      expect(find.byTooltip('Share'), findsNothing);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('reportCardShare')),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      // Tapping Share goes straight to the native OS share sheet — no Ayma
      // intermediate sheet, no per-app buttons. (The real render + system
      // sheet is covered by the service tests; here a capturing fake records
      // that the button is wired to the native share with the smart-link
      // caption.)
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('reportCardShare')));
        for (var i = 0; i < 40 && shares.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(shares, hasLength(1));
      expect(shares.single, contains('https://justabot.info/get'));
      // No per-app share buttons / intermediate sheet survive anywhere.
      for (final gone in ['WhatsApp', 'Instagram', 'Instagram Story', 'More…']) {
        expect(find.text(gone), findsNothing);
      }
    });

    testWidgets('no card or Share when a score is missing', (tester) async {
      final img = await _decoded(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: AppearanceReportScreen(
            reportId: 'current',
            myUid: 'u1',
            apiClient: _api(_report(bodyScore: false)),
            profileService: _Profile(),
            imageFor: (_) => DecodedImage(img),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Brown'), findsOneWidget);
      expect(find.byType(AppearanceReportCard), findsNothing);
      expect(find.byKey(const ValueKey('reportCardShare')), findsNothing);
      expect(find.text('What to do next'), findsNothing);
    });
  });

  group('remove from card (model)', () {
    // A report whose analysed-photo pool has `poolSize` photos: face.jpg,
    // body.jpg, then attr photos.
    AppearanceCardData data(int poolSize) => AppearanceCardData.fromReport(
      _living(_report(attrPhotos: (poolSize - 2).clamp(0, 99))),
    )!;

    test('visible is the pool minus hidden, capped at four', () {
      final d = data(6);
      expect(d.pool, hasLength(6));
      expect(d.visible.map((p) => p.url), [
        'https://x/face.jpg',
        'https://x/body.jpg',
        'https://x/attr0.jpg',
        'https://x/attr1.jpg',
      ]);
    });

    test('removing a shown photo slides in the next pooled one', () {
      final d = data(5); // one spare beyond the four shown
      final removed = d.visible.first.id;
      final after = d.withHidden({removed});
      expect(after.visible, hasLength(4)); // still four — the spare filled in
      expect(after.visible.map((p) => p.id), isNot(contains(removed)));
      // The previously-unshown fifth photo is now on the card.
      expect(after.visible.map((p) => p.url), contains('https://x/attr2.jpg'));
    });

    test('pool exhausted: removing shrinks the card', () {
      final d = data(4); // no spare
      final after = d.withHidden({d.visible.first.id});
      expect(after.visible, hasLength(3));
    });

    test('hiding every photo leaves nothing to show', () {
      final d = data(4);
      final after = d.withHidden({for (final p in d.pool) p.id});
      expect(after.visible, isEmpty);
    });

    test('hidden ids come from the report meta, stale ones dropped', () {
      final report = _report(attrPhotos: 2);
      report['meta'] = {
        'owner_uid': 'u1',
        'viewer_can_edit': true,
        // one real id + one that is not in the pool (stale).
        'card_hidden_photos': ['https://x/body.jpg', 'https://x/gone.jpg'],
      };
      final d = AppearanceCardData.fromReport(_living(report))!;
      expect(d.hidden, {'https://x/body.jpg'});
      expect(d.visible.map((p) => p.url), isNot(contains('https://x/body.jpg')));
    });
  });

  group('AppearanceReportCard remove affordance', () {
    testWidgets('a tap reports the photo index to remove', (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      int? tapped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppearanceReportCard(
                data: _data(),
                name: 'Suhail',
                accent: AymaColors.accent,
                photos: _photos(4),
                onRemovePhoto: (i) => tapped = i,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('reportCardRemove2')));
      expect(tapped, 2);
    });

    testWidgets('X controls show only when interactive, never in the PNG', (
      tester,
    ) async {
      // The exported share image renders with onRemovePhoto == null, so it
      // carries no X controls; the live card (callback given) does.
      await tester.pumpWidget(_card(_data(), photos: 4));
      expect(find.byKey(const ValueKey('reportCardRemove0')), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppearanceReportCard(
                data: _data(),
                name: 'Suhail',
                accent: AymaColors.accent,
                photos: _photos(4),
                onRemovePhoto: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('reportCardRemove0')), findsOneWidget);
      expect(find.byKey(const ValueKey('reportCardRemove3')), findsOneWidget);
    });
  });

  group('remove from card (screen)', () {
    // Serves the report, and records every hidden-list the card persists.
    ({ApiClient api, List<List<String>> posted}) recordingApi(
      Map<String, dynamic> rep,
    ) {
      final posted = <List<String>>[];
      final api = ApiClient(
        httpClient: MockClient((req) async {
          if (req.url.path == '/appearance/card/hidden') {
            posted.add(
              ((jsonDecode(req.body) as Map)['hidden'] as List).cast<String>(),
            );
            return http.Response(
              jsonEncode({'hidden': posted.last}),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(rep),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
        auth: MockFirebaseAuth(signedIn: true),
      );
      return (api: api, posted: posted);
    }

    Future<List<List<String>>> pump(
      WidgetTester tester,
      Map<String, dynamic> rep,
    ) async {
      final img = await _decoded(tester);
      final rec = recordingApi(rep);
      await tester.pumpWidget(
        MaterialApp(
          home: AppearanceReportScreen(
            reportId: 'current',
            myUid: 'u1',
            apiClient: rec.api,
            profileService: _Profile(),
            imageFor: (_) => DecodedImage(img),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return rec.posted;
    }

    testWidgets('remove persists the hidden id and offers Undo', (
      tester,
    ) async {
      // Pool of five, four shown; removing one slides the fifth in, persists
      // the removed id, and offers Undo which persists the empty list again.
      final posted = await pump(tester, _report(attrPhotos: 3));
      expect(_screenPhotoImages, findsNWidgets(4));

      await tester.tap(find.byKey(const ValueKey('reportCardRemove0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_screenPhotoImages, findsNWidgets(4)); // the spare filled in
      expect(posted.last, hasLength(1));
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(posted.last, isEmpty);
    });

    testWidgets('a saved hidden list keeps photos off the card (and the share '
        'image)', (tester) async {
      // The report meta already hides body.jpg: the card never shows it, so
      // neither does the PNG rendered from the same visible set.
      final rep = _report(attrPhotos: 2);
      rep['meta'] = {
        'owner_uid': 'u1',
        'viewer_can_edit': true,
        'card_hidden_photos': ['https://x/body.jpg'],
      };
      await pump(tester, rep);
      expect(find.byType(AppearanceReportCard), findsOneWidget);
      // Four analysed photos, one hidden -> three on the card.
      expect(_screenPhotoImages, findsNWidgets(3));
    });

    testWidgets('every photo hidden falls back to the normal report', (
      tester,
    ) async {
      final rep = _report(attrPhotos: 2);
      rep['meta'] = {
        'owner_uid': 'u1',
        'viewer_can_edit': true,
        'card_hidden_photos': [
          'https://x/face.jpg',
          'https://x/body.jpg',
          'https://x/attr0.jpg',
          'https://x/attr1.jpg',
        ],
      };
      await pump(tester, rep);
      expect(find.byType(AppearanceReportCard), findsNothing);
      expect(find.byKey(const ValueKey('reportCardShare')), findsNothing);
      // The full report is still shown.
      expect(find.text('Brown'), findsOneWidget);
    });
  });

  group('ReportCardShare native share', () {
    late Directory tmp;
    late List<ShareParams> system;

    ReportCardShare svc() => ReportCardShare(
      tempDir: tmp,
      systemShare: (p) async => system.add(p),
    );

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('card_share');
      system = [];
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('share opens the native sheet with the card image and caption',
        () async {
      await svc().share(
        _png,
        caption: ReportCardShare.captionFor('AB12cd'),
        origin: const Rect.fromLTWH(1, 2, 3, 4),
      );
      final p = system.single;
      // The caption carries the Ayma smart link (with the referral code).
      expect(p.text, contains('Get your report on Ayma'));
      expect(p.text, contains('https://justabot.info/get?r=AB12cd'));
      // The rendered card rides along as a PNG file...
      final file = p.files!.single;
      expect(file.mimeType, 'image/png');
      expect(File(file.path).readAsBytesSync(), _png);
      // ...and the iPad popover anchors to the Share button's rect.
      expect(p.sharePositionOrigin, const Rect.fromLTWH(1, 2, 3, 4));
    });

    test('share falls back to the default caption when none is given',
        () async {
      await svc().share(_png);
      expect(system.single.text, ReportCardShare.caption);
    });
  });

  group('ReportCardShare smart-link caption', () {
    test('default caption carries the plain /get smart link', () {
      expect(
        ReportCardShare.caption,
        'Get your report on Ayma 💘 https://justabot.info/get',
      );
    });

    test('captionFor appends the referral code as ?r=', () {
      expect(
        ReportCardShare.captionFor('AB12cd'),
        'Get your report on Ayma 💘 https://justabot.info/get?r=AB12cd',
      );
    });

    test('captionFor with no code is the plain link', () {
      expect(ReportCardShare.captionFor(null), ReportCardShare.caption);
      expect(ReportCardShare.captionFor('  '), ReportCardShare.caption);
    });
  });

}

/// A [ReportCardShare] that records a share instead of rendering the card and
/// opening a real OS share sheet, so the screen test can assert the Share
/// button is wired to the native share (and the caption) without the heavy
/// offscreen render. Overrides [shareCard] so no [renderPng] runs.
class _CapturingShare extends ReportCardShare {
  _CapturingShare(this.captions);

  final List<String?> captions;

  @override
  Future<void> shareCard(
    Widget card, {
    required ui.FlutterView view,
    required Size logicalSize,
    Rect? origin,
    String? caption,
  }) async =>
      captions.add(caption);
}
