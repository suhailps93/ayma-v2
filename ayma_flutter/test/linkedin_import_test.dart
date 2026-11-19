import 'package:ayma_flutter/screens/linkedin_import_screen.dart';
import 'package:ayma_flutter/services/tour_anchors.dart';
import 'package:ayma_flutter/services/tour_content.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// LinkedIn work-history import (founder order 2026-11-18). The import is the
/// Career-timeline entry point: the user uploads their LinkedIn Positions.csv
/// (data export) and Ayma builds dated career nodes. These assert the screen
/// the Career/Settings entries open explains the flow and offers the file pick,
/// and that the feature-tour entry points at its real UI anchor.
void main() {
  testWidgets('the import screen explains the data-export flow and offers the '
      'file picker', (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(theme: AymaTheme.light, home: const LinkedInImportScreen()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Import from LinkedIn'), findsOneWidget);
    expect(find.text('Bring in your work history'), findsOneWidget);
    // The data-export route, stated honestly — no password, no scraping.
    expect(find.textContaining('data export'), findsWidgets);
    expect(find.textContaining('nothing scraped'), findsOneWidget);
    // The step that names the actual file the parser reads.
    expect(find.textContaining('Positions.csv'), findsWidgets);
    // The file-pick action.
    expect(find.text('Choose your Positions.csv'), findsOneWidget);
    expect(find.byIcon(Icons.upload_file_outlined), findsOneWidget);
  });

  test('the feature tour spotlights the import entry at its real UI anchor', () {
    final feature =
        tourFeatures.firstWhere((f) => f.featureId == 'linkedin_import');
    expect(feature.anchorId, TourAnchors.storyLinkedinImport);
    expect(feature.tab, 3); // the Profile tab, where Your Story lives
    expect(feature.subtitle, contains('LinkedIn'));
  });
}
