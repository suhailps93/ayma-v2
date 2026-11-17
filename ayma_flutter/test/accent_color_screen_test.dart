import 'package:ayma_flutter/screens/accent_color_screen.dart';
import 'package:ayma_flutter/services/accent_color_controller.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeProfiles extends ProfileService {
  _FakeProfiles()
    : super(
        auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')),
      );

  final List<Color> serverWrites = [];

  @override
  Future<Color?> getAccentColor() async => null;

  @override
  Future<void> setAccentColor(Color color) async {
    serverWrites.add(color);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget host(AccentColorController c) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => MaterialApp(
      theme: AymaTheme.lightWithAccent(c.color),
      home: AccentColorScreen(controller: c),
    ),
  );

  // Pumping an unrelated tree disposes the picker's State — the exact trigger
  // for "the user left the screen" (back arrow, Android back, swipe, nav away).
  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
  }

  Future<String?> accentPref() async =>
      (await SharedPreferences.getInstance()).getString('accent_color_hex');

  testWidgets(
    'founder path (a): dragging the hue strip previews live WITHOUT persisting',
    (tester) async {
      final profiles = _FakeProfiles();
      final c = AccentColorController(profileService: profiles);
      await tester.pumpWidget(host(c));
      await tester.pump(const Duration(milliseconds: 400));

      final before = c.color;
      await tester.drag(find.byKey(const Key('hueStrip')), const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 400));

      // Live repaint happened in-memory…
      expect(c.color, isNot(equals(before)));
      // …but nothing was saved: no Firestore write, no local pref.
      expect(profiles.serverWrites, isEmpty);
      expect(await accentPref(), isNull);
    },
  );

  testWidgets(
    'founder path (b): "Use this color" persists the pick (local + server)',
    (tester) async {
      final profiles = _FakeProfiles();
      final c = AccentColorController(profileService: profiles);
      await tester.pumpWidget(host(c));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.drag(find.byKey(const Key('hueStrip')), const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 400));
      final previewed = c.color;
      expect(profiles.serverWrites, isEmpty); // still only a preview

      await tester.scrollUntilVisible(
        find.byKey(const Key('useThisColor')),
        200,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('useThisColor')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(profiles.serverWrites, isNotEmpty);
      expect(profiles.serverWrites.last, previewed);
      expect(await accentPref(), isNotNull);
    },
  );

  testWidgets(
    'founder path (c): leaving WITHOUT "Use this color" reverts and writes '
    'nothing',
    (tester) async {
      final profiles = _FakeProfiles();
      final c = AccentColorController(profileService: profiles);
      final saved = c.color;
      await tester.pumpWidget(host(c));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.drag(find.byKey(const Key('hueStrip')), const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.color, isNot(equals(saved))); // previewed away

      await leave(tester);

      // Reverted to the saved baseline, and nothing persisted.
      expect(c.color, saved);
      expect(profiles.serverWrites, isEmpty);
      expect(await accentPref(), isNull);
    },
  );

  testWidgets(
    'founder path (d): committing then leaving keeps the committed colour',
    (tester) async {
      final profiles = _FakeProfiles();
      final c = AccentColorController(profileService: profiles);
      await tester.pumpWidget(host(c));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.drag(find.byKey(const Key('hueStrip')), const Offset(80, 0));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.scrollUntilVisible(
        find.byKey(const Key('useThisColor')),
        200,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('useThisColor')));
      await tester.pump(const Duration(milliseconds: 400));
      final committed = c.color;

      await leave(tester);

      // No revert: the committed colour stands; no extra write on leave.
      expect(c.color, committed);
      expect(profiles.serverWrites, [committed]);
    },
  );

  testWidgets('reset previews the default WITHOUT persisting', (tester) async {
    final profiles = _FakeProfiles();
    final c = AccentColorController(profileService: profiles);
    await c.set(const Color(0xFF3355AA));
    await tester.pumpWidget(host(c));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.scrollUntilVisible(find.text('Reset to default'), 200);
    await tester.ensureVisible(find.text('Reset to default'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Reset to default'));
    await tester.pump(const Duration(milliseconds: 400));

    // Previews the default live, but only the earlier set() ever persisted.
    expect(c.color, AymaColors.accent);
    expect(profiles.serverWrites, [const Color(0xFF3355AA)]);
  });

  testWidgets('neutral swatches preview only (no persistence)', (tester) async {
    final profiles = _FakeProfiles();
    final c = AccentColorController(profileService: profiles);
    await tester.pumpWidget(host(c));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.scrollUntilVisible(find.text('Black'), 200);
    await tester.ensureVisible(find.text('Black'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Black'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(c.color, Colors.black); // live preview
    expect(profiles.serverWrites, isEmpty); // but not saved
    expect(await accentPref(), isNull);
  });

  testWidgets('the preset swatch row is gone', (tester) async {
    final c = AccentColorController(profileService: _FakeProfiles());
    await tester.pumpWidget(host(c));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('accentPreset_green')), findsNothing);
    expect(find.byKey(const Key('hueStrip')), findsOneWidget);
  });

  testWidgets(
    'sliders drop the inactiveColor override (theme track) and keep active fg '
    '(defect 11); the accent Wrap carries runSpacing 8 (defect 12)',
    (tester) async {
      final c = AccentColorController(profileService: _FakeProfiles());
      await tester.pumpWidget(host(c));
      await tester.pump(const Duration(milliseconds: 400));

      final ac = tester.element(find.byType(AccentColorScreen)).ac;
      for (final key in const ['accentSaturation', 'accentBrightness']) {
        final slider = tester.widget<Slider>(find.byKey(Key(key)));
        // No per-screen override: the theme's sliderTheme.inactiveTrackColor
        // (= ac.track) supplies the inactive track.
        expect(slider.inactiveColor, isNull);
        // The neutral active track is deliberate on the accent-picking screen.
        expect(slider.activeColor, ac.fg);
      }

      final wrap = tester.widget<Wrap>(find.byType(Wrap));
      expect(wrap.runSpacing, 8);
      expect(wrap.spacing, 12);
    },
  );
}
