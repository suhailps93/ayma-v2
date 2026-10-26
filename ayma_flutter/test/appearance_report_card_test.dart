// The shareable Appearance report card: what it may show (photos capped at
// four, both scores always, positive findings only), long-text safety, the
// Share sheet, the 1080x1920 PNG export, and the per-target hand-off.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/models/appearance_card.dart';
import 'package:ayma_flutter/models/living_report.dart';
import 'package:ayma_flutter/screens/appearance_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/gallery_saver.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/report_card_share.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/appearance_report_card.dart';
import 'package:ayma_flutter/widgets/report_card_share_sheet.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:share_plus/share_plus.dart';

final Uint8List _png = File('test/fixtures/tiny.png').readAsBytesSync();

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
    photoUrls: d.photoUrls,
    photoLabels: d.photoLabels,
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
      expect(find.byType(Image), findsNWidgets(4));
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
      expect(find.byType(Image), findsNWidgets(4));
    });

    testWidgets('fewer photos draw no empty frames', (tester) async {
      await tester.pumpWidget(_card(_data(), photos: 2));
      expect(find.byType(Image), findsNWidgets(2));
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
      await tester.pumpWidget(
        MaterialApp(
          home: AppearanceReportScreen(
            reportId: 'current',
            myUid: 'u1',
            apiClient: _api(_report()),
            profileService: _Profile(),
            imageFor: (_) => DecodedImage(img),
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
      await tester.tap(find.byKey(const ValueKey('reportCardShare')));
      await tester.pumpAndSettle();
      final labels = [for (final o in ReportCardShareSheet.options) o.$2];
      expect(labels, ['WhatsApp', 'Instagram Stories', 'Save image', 'More…']);
      for (final l in labels) {
        expect(find.text(l), findsOneWidget);
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

  group('ReportCardShare targets', () {
    late Directory tmp;
    late List<MethodCall> shareCalls;
    late List<MethodCall> saveCalls;
    late List<ShareParams> system;
    const shareChannel = MethodChannel('ayma/share');
    const saveChannel = MethodChannel('ayma/media_save');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    ReportCardShare svc() => ReportCardShare(
      shareChannel: shareChannel,
      gallery: const GallerySaver(channel: saveChannel),
      tempDir: tmp,
      systemShare: (p) async => system.add(p),
    );

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('card_share');
      shareCalls = [];
      saveCalls = [];
      system = [];
      messenger.setMockMethodCallHandler(saveChannel, (c) async {
        saveCalls.add(c);
        return 'Pictures/Ayma';
      });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(shareChannel, null);
      messenger.setMockMethodCallHandler(saveChannel, null);
      tmp.deleteSync(recursive: true);
    });

    test('Android WhatsApp sends the image straight to WhatsApp', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(shareChannel, (c) async {
        shareCalls.add(c);
        return true;
      });
      expect(await svc().share(CardShareTarget.whatsapp, _png), isNull);
      final c = shareCalls.single;
      expect(c.method, 'sendToApp');
      expect(c.arguments['packages'], ['com.whatsapp', 'com.whatsapp.w4b']);
      expect(c.arguments['text'], 'Get your report on Ayma');
      expect(c.arguments['text'], isNot(contains('http')));
      expect(File(c.arguments['path'] as String).readAsBytesSync(), _png);
      expect(system, isEmpty);
    });

    test('Instagram not installed falls back to the share sheet', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(shareChannel, (c) async {
        shareCalls.add(c);
        return false;
      });
      await svc().share(CardShareTarget.instagram, _png);
      expect(shareCalls.single.arguments['packages'], [
        'com.instagram.android',
      ]);
      expect(system.single.files!.single.mimeType, 'image/png');
    });

    test(
      'iOS WhatsApp/Instagram and More use the system share sheet',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        await svc().share(CardShareTarget.whatsapp, _png);
        await svc().share(CardShareTarget.more, _png);
        expect(shareCalls, isEmpty);
        expect(system, hasLength(2));
        expect(system.first.text, 'Get your report on Ayma');
      },
    );

    test('Save image writes the PNG to the gallery, nothing else', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(
        await svc().share(CardShareTarget.save, _png),
        'Saved to Pictures/Ayma',
      );
      expect(saveCalls.single.arguments['mime'], 'image/png');
      expect(saveCalls.single.arguments['bytes'], _png);
      expect(system, isEmpty);
    });
  });
}
