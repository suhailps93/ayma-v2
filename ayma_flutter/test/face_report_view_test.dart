import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/face_report_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FaceReport _sample() => FaceReport.fromMap(const {
      'usable': true,
      'overall_score': 6.9,
      'verdict': 'Above average',
      'verdict_note': 'Strong eyes, let down by skin texture.',
      'features': [
        {'name': 'symmetry', 'score': 7.0, 'note': 'Minor jaw asymmetry.'},
        {'name': 'skin_quality', 'score': 5.5, 'note': 'Visible texture.'},
      ],
      'quick_facts': {
        'face_shape': 'oval',
        'best_feature': 'eyes',
      },
      'strengths': ['Expressive, well-proportioned eyes'],
      'improvements': ['Even out skin texture'],
      'recommendations': [
        {'category': 'skincare', 'text': 'Nightly retinoid for texture.'},
      ],
    });

void main() {
  testWidgets('renders the score, a feature, a strength and a recommendation',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(child: FaceReportView(report: _sample())),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('FACIAL BEAUTY REPORT'), findsOneWidget);
    expect(find.text('6.9'), findsOneWidget);
    expect(find.text('Above average'), findsOneWidget);
    expect(find.text('Symmetry'), findsOneWidget);
    expect(find.text('Skin Quality'), findsOneWidget);
    expect(find.text('Expressive, well-proportioned eyes'), findsOneWidget);
    expect(find.text('Even out skin texture'), findsOneWidget);
    expect(find.text('SKINCARE'), findsOneWidget);
    expect(find.text('Nightly retinoid for texture.'), findsOneWidget);
  });

  testWidgets('renders the analysed photo when an imageUrl is given',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: FaceReportView(
            report: _sample(),
            imageUrl: 'https://example.com/photo.jpg',
          ),
        ),
      ),
    ));
    await tester.pump(); // don't settle — a real Image.network never resolves
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('degrades gracefully with no photo and no crash for an old '
      'report', (tester) async {
    // A report stored before source_photos existed: no imageUrl at all.
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(child: FaceReportView(report: _sample())),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
