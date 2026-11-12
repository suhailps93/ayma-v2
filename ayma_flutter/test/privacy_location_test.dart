import 'package:ayma_flutter/screens/privacy_settings_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake ApiClient for the Privacy screen's initState reads.
class _FakeApi extends ApiClient {
  _FakeApi(this._patterns) : super(auth: MockFirebaseAuth(signedIn: true));
  final List<LocationPattern> _patterns;
  @override
  Future<bool> verificationStatus() async => false;
  @override
  Future<List<LocationPattern>> locationPatterns() async => _patterns;
}

Future<ProfileService> _profiles({required bool masterOn}) async {
  final fs = FakeFirebaseFirestore();
  await fs.doc('users/me/profile/main').set({
    'location_master_enabled': masterOn,
  });
  return ProfileService(
    auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')),
    firestore: fs,
  );
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(theme: AymaTheme.light, home: screen));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('shows master, background and location-log switches when master on',
      (tester) async {
    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: await _profiles(masterOn: true),
        api: _FakeApi(const []),
      ),
    );
    expect(find.byKey(const Key('settings_location_master')), findsOneWidget);
    expect(find.byKey(const Key('settings_location_background')),
        findsOneWidget);
    expect(find.byKey(const Key('settings_date_moments')), findsOneWidget);
    expect(find.text('Location log'), findsOneWidget);
  });

  testWidgets('master off hides the sub-controls', (tester) async {
    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: await _profiles(masterOn: false),
        api: _FakeApi(const []),
      ),
    );
    expect(find.byKey(const Key('settings_location_master')), findsOneWidget);
    // Kill switch off: the sub-controls are gone, a plain note remains.
    expect(find.byKey(const Key('settings_location_background')), findsNothing);
    expect(find.text('Location log'), findsNothing);
    expect(find.textContaining('Location is fully off'), findsOneWidget);
  });

  testWidgets('renders learned routines as chips', (tester) async {
    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: await _profiles(masterOn: true),
        api: _FakeApi(const [
          LocationPattern(label: 'morning walks', placeKind: 'park', count: 4),
          LocationPattern(label: 'Sunday hikes', placeKind: 'trailhead', count: 3),
        ]),
      ),
    );
    expect(find.text('What Ayma has learned from your places'), findsOneWidget);
    expect(find.text('morning walks'), findsOneWidget);
    expect(find.text('Sunday hikes'), findsOneWidget);
  });
}
