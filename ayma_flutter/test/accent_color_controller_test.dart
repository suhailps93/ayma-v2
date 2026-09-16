import 'package:ayma_flutter/services/accent_color_controller.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeProfiles extends ProfileService {
  _FakeProfiles({this.remote})
      : super(auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')));

  Color? remote;
  final List<Color> serverWrites = [];
  bool throwOnWrite = false;

  @override
  Future<Color?> getAccentColor() async => remote;

  @override
  Future<void> setAccentColor(Color color) async {
    if (throwOnWrite) throw StateError('offline');
    serverWrites.add(color);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to Cherry Fuchsia when nothing is stored', () async {
    final c = AccentColorController(profileService: _FakeProfiles());
    expect(c.color, AymaColors.accent);
    await c.load();
    expect(c.color, AymaColors.accent);
  });

  test('load() picks up a local SharedPreferences value first', () async {
    SharedPreferences.setMockInitialValues({'accent_color_hex': '#112233'});
    final profiles = _FakeProfiles(remote: const Color(0xFF445566));
    final c = AccentColorController(profileService: profiles);
    await c.load();
    // Local wins — the remote fetch is never even needed.
    expect(c.color, const Color(0xFF112233));
  });

  test('load() falls back to the server copy when local is empty', () async {
    final profiles = _FakeProfiles(remote: const Color(0xFF9911CC));
    final c = AccentColorController(profileService: profiles);
    await c.load();
    expect(c.color, const Color(0xFF9911CC));
    // And caches it locally for next time.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('accent_color_hex'), '#9911cc');
  });

  test('set() persists locally, mirrors to the server, and notifies',
      () async {
    final profiles = _FakeProfiles();
    final c = AccentColorController(profileService: profiles);
    var notified = 0;
    c.addListener(() => notified++);

    await c.set(const Color(0xFF00AABB));

    expect(c.color, const Color(0xFF00AABB));
    expect(notified, 1);
    expect(profiles.serverWrites, [const Color(0xFF00AABB)]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('accent_color_hex'), '#00aabb');
  });

  test('set() still persists even when the colour matches (post-preview)',
      () async {
    final profiles = _FakeProfiles();
    final c = AccentColorController(profileService: profiles);
    c.preview(const Color(0xFF00AABB)); // in-memory only, no persistence
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('accent_color_hex'), isNull);

    await c.set(const Color(0xFF00AABB)); // same colour, must still persist
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('accent_color_hex'), '#00aabb');
    expect(profiles.serverWrites, [const Color(0xFF00AABB)]);
  });

  test('preview() notifies live but never touches storage', () async {
    final profiles = _FakeProfiles();
    final c = AccentColorController(profileService: profiles);
    var notified = 0;
    c.addListener(() => notified++);

    c.preview(const Color(0xFF123456));

    expect(c.color, const Color(0xFF123456));
    expect(notified, 1);
    expect(profiles.serverWrites, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('accent_color_hex'), isNull);
  });

  test('set() keeps the local pick even if the server write fails',
      () async {
    final profiles = _FakeProfiles()..throwOnWrite = true;
    final c = AccentColorController(profileService: profiles);
    await c.set(const Color(0xFF654321));
    expect(c.color, const Color(0xFF654321));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('accent_color_hex'), '#654321');
  });

  test('resetToDefault() goes back to Cherry Fuchsia', () async {
    final profiles = _FakeProfiles();
    final c = AccentColorController(profileService: profiles);
    await c.set(const Color(0xFF654321));
    await c.resetToDefault();
    expect(c.color, AymaColors.accent);
    expect(profiles.serverWrites.last, AymaColors.accent);
  });
}
