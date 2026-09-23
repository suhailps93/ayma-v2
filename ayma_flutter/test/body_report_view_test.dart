import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/body_report_view.dart';
import 'package:ayma_flutter/widgets/score_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BodyReport _sample() => BodyReport.fromMap(const {
      'usable': true,
      'overall_score': 6.4,
      'verdict': 'Solid base',
      'verdict_note': 'Good frame, needs lower body fat.',
      'features': [
        {'name': 'frame', 'score': 7.5, 'note': 'Broad clavicles.'},
        {'name': 'v_taper', 'score': 6.0, 'note': 'Waist a touch wide.'},
      ],
      'quick_facts': {
        'body_type': 'mesomorph',
        'weakest_area': 'midsection',
      },
      'strengths': ['Naturally wide shoulder frame'],
      'improvements': ['Drop body fat to sharpen the waist'],
      'recommendations': [
        {'category': 'training', 'text': 'Add horizontal rows.'},
      ],
    });

void main() {
  testWidgets('renders the score, a feature, a strength and a recommendation',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(child: BodyReportView(report: _sample())),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('PHYSIQUE REPORT'), findsOneWidget);
    expect(find.text('6.4'), findsOneWidget);
    expect(find.text('Solid base'), findsOneWidget);
    expect(find.text('Frame'), findsOneWidget);
    expect(find.text('V Taper'), findsOneWidget);
    expect(find.text('Naturally wide shoulder frame'), findsOneWidget);
    expect(find.text('Drop body fat to sharpen the waist'), findsOneWidget);
    expect(find.text('TRAINING'), findsOneWidget);
    expect(find.text('Add horizontal rows.'), findsOneWidget);

    // One flat, out-of-10 score bar per feature (unjudgmental — no banding).
    final bars = tester.widgetList<ScoreBar>(find.byType(ScoreBar)).toList();
    expect(bars, hasLength(2));
    for (final bar in bars) {
      expect(bar.max, 10);
      expect(bar.colorFor, isNull);
    }
    expect(bars[0].value, 7.5);
    expect(bars[1].value, 6.0);
  });

  testWidgets('renders the analysed photo when an imageUrl is given',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: BodyReportView(
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
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(child: BodyReportView(report: _sample())),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
