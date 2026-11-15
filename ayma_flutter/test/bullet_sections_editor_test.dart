import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/bullet_sections_editor.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiClient {
  _FakeApi({required this.sections})
      : super(auth: MockFirebaseAuth(signedIn: true));

  final List<BulletSection> sections;
  final List<(String, List<StoryBullet>)> bulletSaves = [];
  final List<(String, List<StoryBullet>)> bulletCreates = [];

  @override
  Future<List<BulletSection>> profileBullets() async => sections;

  @override
  Future<void> profileBulletsSave(
          String pageId, List<StoryBullet> bullets) async =>
      bulletSaves.add((pageId, bullets));

  @override
  Future<void> profileBulletsCreate(
          String pageType, List<StoryBullet> bullets) async =>
      bulletCreates.add((pageType, bullets));
}

void main() {
  testWidgets(
      'BulletSectionsEditor renders without crash when duplicate pageTypes exist with distinct pageIds',
      (tester) async {
    final api = _FakeApi(
      sections: const [
        BulletSection(
          pageType: 'dealbreakers',
          pageId: 'dealbreakers',
          title: 'Non-Negotiables',
          order: 3,
          bullets: [
            StoryBullet(
                id: 'b1', text: 'Must love dogs.', visibility: 'public'),
          ],
        ),
        BulletSection(
          pageType: 'dealbreakers',
          pageId: 'core-non-negotiables',
          title: 'Core Non-Negotiables',
          order: 3,
          bullets: [
            StoryBullet(
                id: 'b2',
                text: 'Must want children.',
                visibility: 'private'),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BulletSectionsEditor(api: api),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Does not crash or show error card
    expect(find.text('Could not load your story'), findsNothing);
    expect(find.text('Non-Negotiables'), findsOneWidget);
    expect(find.text('Core Non-Negotiables'), findsOneWidget);
    expect(find.text('Must love dogs.'), findsOneWidget);
    expect(find.text('Must want children.'), findsOneWidget);

    // Cards are keyed by pageId rather than pageType
    expect(
      find.byKey(const ValueKey('bullet_section_dealbreakers')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bullet_section_core-non-negotiables')),
      findsOneWidget,
    );
  });

  testWidgets(
      'BulletSectionsEditor disambiguates duplicate pageTypes even when pageIds are empty or identical',
      (tester) async {
    final api = _FakeApi(
      sections: const [
        BulletSection(
          pageType: 'family',
          pageId: '',
          title: 'Family First',
          order: 7,
        ),
        BulletSection(
          pageType: 'family',
          pageId: '',
          title: 'Family Second',
          order: 7,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BulletSectionsEditor(api: api),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Renders without duplicate key collision
    expect(find.text('Family First'), findsOneWidget);
    expect(find.text('Family Second'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bullet_section_family')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bullet_section_family_1')),
      findsOneWidget,
    );
  });
}
