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

  testWidgets('dragging the hue strip previews and then commits a colour', (
    tester,
  ) async {
    final profiles = _FakeProfiles();
    final c = AccentColorController(profileService: profiles);
    await tester.pumpWidget(host(c));
    await tester.pump(const Duration(milliseconds: 400));

    final strip = find.byKey(const Key('hueStrip'));
    final before = c.color;
    await tester.drag(strip, const Offset(80, 0));
    await tester.pump();
    // Preview applied instantly (in-memory), drag not yet released within
    // this single `drag()` call's synthetic gesture, but by the time drag()
    // returns the pan has already ended, so it should also be committed.
    expect(c.color, isNot(equals(before)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(profiles.serverWrites, isNotEmpty);
    expect(profiles.serverWrites.last, c.color);
  });

  testWidgets('reset returns to Cherry Fuchsia and persists it', (
    tester,
  ) async {
    final profiles = _FakeProfiles();
    final c = AccentColorController(profileService: profiles);
    await c.set(const Color(0xFF3355AA));
    await tester.pumpWidget(host(c));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.scrollUntilVisible(find.text('Reset to Cherry Fuchsia'), 200);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.text('Reset to Cherry Fuchsia'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Reset to Cherry Fuchsia'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(c.color, AymaColors.accent);
    expect(profiles.serverWrites.last, AymaColors.accent);
  });
  testWidgets(
    'neutral presets persist and brightness preserves zero saturation',
    (tester) async {
      final profiles = _FakeProfiles();
      final c = AccentColorController(profileService: profiles);
      await tester.pumpWidget(host(c));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(find.text('Black'));
      await tester.tap(find.text('Black'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.color, Colors.black);
      await tester.tap(find.text('Gray'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.color.r, c.color.g);
      expect(c.color.g, c.color.b);
      final slider = tester.widget<Slider>(
        find.byKey(const Key('accentBrightness')),
      );
      slider.onChanged!(0.8);
      slider.onChangeEnd!(0.8);
      await tester.pump(const Duration(milliseconds: 400));
      expect(HSVColor.fromColor(c.color).saturation, 0);
      expect(HSVColor.fromColor(c.color).value, closeTo(0.8, 0.01));
      expect(profiles.serverWrites.last, c.color);
    },
  );
}
