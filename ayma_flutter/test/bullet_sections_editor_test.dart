import 'dart:async';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/bullet_sections_editor.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiClient {
  _FakeApi({required this.sections})
      : super(auth: MockFirebaseAuth(signedIn: true));

  List<BulletSection> sections;
  final List<(String, List<StoryBullet>)> bulletSaves = [];
  final List<(String, List<StoryBullet>)> bulletCreates = [];

  /// Snapshot of each save's (text, visibility) pairs taken at call time, so a
  /// later in-place mutation of the editor's live list can't rewrite history.
  final List<List<(String, String)>> saveSnapshots = [];

  /// When set, each save blocks on this until completed — lets a test hold a
  /// save "in flight" and act on the UI meanwhile.
  Completer<void>? gate;

  /// After each successful save the editor re-pulls; mirror that by serving the
  /// latest saved bullets back as the section's content.
  bool reflectSavesIntoSections = false;

  @override
  Future<List<BulletSection>> profileBullets() async => sections;

  @override
  Future<void> profileBulletsSave(
      String pageId, List<StoryBullet> bullets) async {
    bulletSaves.add((pageId, bullets));
    saveSnapshots.add([for (final b in bullets) (b.text, b.visibility)]);
    if (gate != null) await gate!.future;
    if (reflectSavesIntoSections) {
      sections = [
        for (final s in sections)
          if (s.pageId == pageId)
            BulletSection(
              pageType: s.pageType,
              pageId: s.pageId,
              title: s.title,
              subtitle: s.subtitle,
              order: s.order,
              bullets: List<StoryBullet>.from(bullets),
            )
          else
            s,
      ];
    }
  }

  @override
  Future<void> profileBulletsCreate(
          String pageType, List<StoryBullet> bullets) async =>
      bulletCreates.add((pageType, bullets));
}

BulletSection _aboutMe(List<StoryBullet> bullets) => BulletSection(
      pageType: 'about_me',
      pageId: 'about_me',
      title: 'About Me',
      order: 1,
      bullets: bullets,
    );

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

  // Scout NOTE 219 leg a: the visibility label cycles public <-> private and
  // persists; it stays live during a save; and a tap while editing both
  // commits the edit and cycles (it doesn't lose to the focus-loss commit).
  group('visibility cycle (NOTE 219 leg a)', () {
    Future<_FakeApi> pumpEditor(WidgetTester tester, _FakeApi api) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BulletSectionsEditor(api: api)),
        ),
      ));
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('a label tap cycles public -> private and persists it',
        (tester) async {
      final api = await pumpEditor(
        tester,
        _FakeApi(sections: [
          _aboutMe(const [
            StoryBullet(id: 'b1', text: 'I grew up in Lisbon.', visibility: 'public'),
          ]),
        ])..reflectSavesIntoSections = true,
      );

      expect(find.text('Public'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('visibility_about_me_0')));
      await tester.pumpAndSettle();

      // Visibly flipped…
      expect(find.text('Private'), findsOneWidget);
      expect(find.text('Public'), findsNothing);
      // …and persisted as private.
      expect(api.saveSnapshots.last, [('I grew up in Lisbon.', 'private')]);
    });

    testWidgets('the label is NOT dead during a save', (tester) async {
      final gate = Completer<void>();
      final api = await pumpEditor(
        tester,
        _FakeApi(sections: [
          _aboutMe(const [
            StoryBullet(id: 'b1', text: 'A line.', visibility: 'public'),
          ]),
        ])..gate = gate,
      );

      // First tap starts a save that hangs on the gate.
      await tester.tap(find.byKey(const ValueKey('visibility_about_me_0')));
      await tester.pump();
      expect(find.text('Private'), findsOneWidget);

      // Second tap WHILE that save is in flight must still flip the label —
      // pre-fix it was a dead no-op (`_saving ? null`).
      await tester.tap(find.byKey(const ValueKey('visibility_about_me_0')));
      await tester.pump();
      expect(find.text('Public'), findsOneWidget,
          reason: 'the chip must stay live during a save');

      // Releasing the save drains the serialised re-save with the latest value.
      gate.complete();
      await tester.pumpAndSettle();
      expect(api.saveSnapshots.last, [('A line.', 'public')]);
    });

    testWidgets('a label tap while editing commits the edit AND cycles',
        (tester) async {
      final api = await pumpEditor(
        tester,
        _FakeApi(sections: [
          _aboutMe(const [
            StoryBullet(id: 'b1', text: 'Original text.', visibility: 'public'),
          ]),
        ])..reflectSavesIntoSections = true,
      );

      // Open the editor on the bullet and change its text.
      await tester.tap(find.text('Original text.'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'Edited text.');
      await tester.pump();

      // Tapping the visibility label commits the edit (focus loss) and cycles.
      await tester.tap(find.byKey(const ValueKey('visibility_about_me_0')));
      await tester.pumpAndSettle();

      // The edit is kept and the visibility is the cycled value — never the
      // stale "stayed Public/Private" the race produced.
      expect(api.saveSnapshots.last, [('Edited text.', 'private')]);
      expect(find.text('Edited text.'), findsOneWidget);
      expect(find.text('Private'), findsOneWidget);
    });
  });

  // Bullet delete asks first (founder order, Nov 15 2026): the trash icon used
  // to delete instantly — how a Scout test bullet vanished during NOTE 219.
  group('bullet delete confirmation', () {
    Future<_FakeApi> pumpEditor(WidgetTester tester, _FakeApi api) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BulletSectionsEditor(api: api)),
        ),
      ));
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('tapping delete shows a confirm dialog and does NOT delete',
        (tester) async {
      final api = await pumpEditor(
        tester,
        _FakeApi(sections: [
          _aboutMe(const [
            StoryBullet(id: 'b1', text: 'Keep me.', visibility: 'public'),
          ]),
        ])..reflectSavesIntoSections = true,
      );

      await tester.tap(find.byKey(const ValueKey('delete_about_me_0')));
      await tester.pumpAndSettle();

      // The confirm dialog is up…
      expect(find.byKey(const ValueKey('delete_bullet_confirm')), findsOneWidget);
      // …and nothing has been deleted or persisted yet.
      expect(find.text('Keep me.'), findsOneWidget);
      expect(api.bulletSaves, isEmpty);
    });

    testWidgets('cancel leaves the bullet untouched', (tester) async {
      final api = await pumpEditor(
        tester,
        _FakeApi(sections: [
          _aboutMe(const [
            StoryBullet(id: 'b1', text: 'Keep me.', visibility: 'public'),
          ]),
        ])..reflectSavesIntoSections = true,
      );

      await tester.tap(find.byKey(const ValueKey('delete_about_me_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete_bullet_cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('delete_bullet_confirm')), findsNothing);
      expect(find.text('Keep me.'), findsOneWidget);
      expect(api.bulletSaves, isEmpty);
    });

    testWidgets('confirming deletes the bullet and persists', (tester) async {
      final api = await pumpEditor(
        tester,
        _FakeApi(sections: [
          _aboutMe(const [
            StoryBullet(id: 'b1', text: 'Delete me.', visibility: 'public'),
            StoryBullet(id: 'b2', text: 'Keep me.', visibility: 'public'),
          ]),
        ])..reflectSavesIntoSections = true,
      );

      await tester.tap(find.byKey(const ValueKey('delete_about_me_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete_bullet_confirm_action')));
      await tester.pumpAndSettle();

      // Dialog gone, the bullet is deleted, and the save persisted the rest.
      expect(find.byKey(const ValueKey('delete_bullet_confirm')), findsNothing);
      expect(find.text('Delete me.'), findsNothing);
      expect(find.text('Keep me.'), findsOneWidget);
      expect(api.saveSnapshots.last, [('Keep me.', 'public')]);
    });
  });

  // Scout NOTE 221: appending text to an existing bullet must keep it ONE
  // bullet with its own visibility — the appended fragment is never split off
  // into a separate (public) bullet. Adding a brand-new bullet still
  // auto-splits multi-sentence input.
  group('edit stays one bullet (NOTE 221)', () {
    Future<_FakeApi> pumpEditor(WidgetTester tester, _FakeApi api) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BulletSectionsEditor(api: api)),
        ),
      ));
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets(
        'appending a sentence to an existing private bullet keeps it one '
        'private bullet (not split, not public)', (tester) async {
      final api = await pumpEditor(
        tester,
        _FakeApi(sections: [
          _aboutMe(const [
            StoryBullet(id: 'b1', text: 'Original.', visibility: 'private'),
          ]),
        ])..reflectSavesIntoSections = true,
      );

      await tester.tap(find.text('Original.'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'Original. Appended.');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // Saved as exactly ONE bullet, keeping its private tag — the appended
      // sentence did not become a second (public) bullet.
      expect(api.saveSnapshots.last, [('Original. Appended.', 'private')]);
      expect(find.text('Original. Appended.'), findsOneWidget);
    });

    testWidgets('adding a NEW bullet still auto-splits multi-sentence input',
        (tester) async {
      final api = await pumpEditor(
        tester,
        _FakeApi(sections: [
          _aboutMe(const [
            StoryBullet(id: 'b1', text: 'Existing.', visibility: 'private'),
          ]),
        ])..reflectSavesIntoSections = true,
      );

      await tester.tap(find.byKey(const ValueKey('add_bullet_about_me')));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'One. Two.');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // The new bullet splits into two; the existing bullet is untouched.
      expect(api.saveSnapshots.last, const [
        ('Existing.', 'private'),
        ('One.', 'private'),
        ('Two.', 'private'),
      ]);
    });
  });
}
