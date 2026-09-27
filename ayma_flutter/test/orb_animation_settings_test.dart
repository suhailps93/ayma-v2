import 'package:ayma_flutter/services/orb_animation_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults: both flags ON (current shipped behavior)', () {
    final s = OrbAnimationSettings();
    expect(s.flutterEnabled, isTrue);
    expect(s.navBarFlutterEnabled, isTrue);
    expect(s.flutterEnabledFor(navBar: false), isTrue);
    expect(s.flutterEnabledFor(navBar: true), isTrue);
  });

  test('setFlutterEnabled persists and a fresh instance loads it back',
      () async {
    final s = OrbAnimationSettings();
    await s.setFlutterEnabled(false);
    expect(s.flutterEnabled, isFalse);

    final fresh = OrbAnimationSettings();
    expect(fresh.flutterEnabled, isTrue, reason: 'default before load');
    await fresh.load();
    expect(fresh.flutterEnabled, isFalse);
    expect(fresh.navBarFlutterEnabled, isTrue);
  });

  test('setNavBarFlutterEnabled persists independently of the master flag',
      () async {
    final s = OrbAnimationSettings();
    await s.setNavBarFlutterEnabled(false);

    final fresh = OrbAnimationSettings();
    await fresh.load();
    expect(fresh.flutterEnabled, isTrue);
    expect(fresh.navBarFlutterEnabled, isFalse);
  });

  test('everywhere-off wins: nav-bar flag is ignored while master is off',
      () async {
    final s = OrbAnimationSettings();
    await s.setFlutterEnabled(false);
    expect(s.flutterEnabledFor(navBar: false), isFalse);
    expect(s.flutterEnabledFor(navBar: true), isFalse);
    // The stored nav-bar choice survives underneath.
    expect(s.navBarFlutterEnabled, isTrue);

    await s.setFlutterEnabled(true);
    expect(s.flutterEnabledFor(navBar: true), isTrue);
  });

  test('nav-only off leaves big orbs animating, stops nav-bar orbs',
      () async {
    final s = OrbAnimationSettings();
    await s.setNavBarFlutterEnabled(false);
    expect(s.flutterEnabledFor(navBar: false), isTrue);
    expect(s.flutterEnabledFor(navBar: true), isFalse);
  });

  test('notifies listeners on change, not on a no-op set', () async {
    final s = OrbAnimationSettings();
    var notified = 0;
    s.addListener(() => notified++);
    await s.setFlutterEnabled(true); // unchanged
    expect(notified, 0);
    await s.setFlutterEnabled(false);
    expect(notified, 1);
    await s.setNavBarFlutterEnabled(false);
    expect(notified, 2);
  });

  test('load without stored values keeps the defaults', () async {
    final s = OrbAnimationSettings();
    await s.load();
    expect(s.flutterEnabled, isTrue);
    expect(s.navBarFlutterEnabled, isTrue);
  });
}
