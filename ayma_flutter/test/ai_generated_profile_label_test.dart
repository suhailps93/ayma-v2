// The "AI-generated profile" label must render in the profile header ONLY for
// an AI-generated persona (sim / demo / seed), and NEVER for a real user. A
// real person mislabelled as AI-generated is the worst outcome, so the default
// (absent flag) must resolve to no label.
import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _labelText = 'AI-generated profile';

Future<void> _pump(WidgetTester tester, {required bool aiGenerated}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProfilePhotoHeader(
            photos: const [],
            seed: 'u1',
            name: 'Dana',
            age: 30,
            location: 'Berlin',
            aiGenerated: aiGenerated,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the label for an AI-generated persona', (tester) async {
    await _pump(tester, aiGenerated: true);
    expect(find.text(_labelText), findsOneWidget);
    // The real identity still renders alongside the badge.
    expect(find.text('Dana'), findsOneWidget);
  });

  testWidgets('never shows the label for a real user', (tester) async {
    await _pump(tester, aiGenerated: false);
    expect(find.text(_labelText), findsNothing);
    expect(find.text('Dana'), findsOneWidget);
  });

  group('PublicProfile.aiGenerated parsing', () {
    test('an AI-generated payload sets the flag', () {
      final p = PublicProfile.fromMap(const {
        'uid': 'demo_practice_maya',
        'name': 'Maya',
        'ai_generated': true,
      });
      expect(p.aiGenerated, isTrue);
    });

    test('a real-user payload leaves the flag false', () {
      final p = PublicProfile.fromMap(const {
        'uid': 'her',
        'name': 'Dillu',
      });
      expect(p.aiGenerated, isFalse);
    });

    test('a non-bool / unknown value resolves to false (no label)', () {
      final p = PublicProfile.fromMap(const {
        'uid': 'her',
        'name': 'Dillu',
        'ai_generated': 'yes',
      });
      expect(p.aiGenerated, isFalse);
    });
  });
}
