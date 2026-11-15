import 'package:ayma_flutter/screens/privacy_settings_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/location_service.dart';
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

class _FakeLocationService extends LocationService {
  _FakeLocationService({
    this.hasBackground = false,
    this.checkPermissionResult = LocationPermission.denied,
    this.requestPermissionResult = LocationPermission.denied,
  });

  bool hasBackground;
  LocationPermission checkPermissionResult;
  LocationPermission requestPermissionResult;
  int checkCalls = 0;
  int requestCalls = 0;
  int openSettingsCalls = 0;

  @override
  Future<bool> hasBackgroundPermission() async => hasBackground;

  @override
  Future<LocationPermission> checkPermission() async {
    checkCalls++;
    return checkPermissionResult;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requestCalls++;
    if (requestPermissionResult == LocationPermission.always) {
      hasBackground = true;
    }
    return requestPermissionResult;
  }

  @override
  Future<bool> openAppSettings() async {
    openSettingsCalls++;
    return true;
  }
}

Future<ProfileService> _profiles({
  required bool masterOn,
  bool logOn = false,
}) async {
  final fs = FakeFirebaseFirestore();
  await fs.doc('users/me/profile/main').set({
    'location_master_enabled': masterOn,
    'location_log_enabled': logOn,
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

  testWidgets(
      'enabling Location log when permission already granted turns toggle on without prompt',
      (tester) async {
    final profiles = await _profiles(masterOn: true, logOn: false);
    final loc = _FakeLocationService(hasBackground: true);

    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: profiles,
        api: _FakeApi(const []),
        locationService: loc,
      ),
    );

    await tester.tap(find.text('Location log'));
    await tester.pumpAndSettle();

    expect(loc.requestCalls, 0);
    expect(loc.openSettingsCalls, 0);
    expect(await profiles.locationLogEnabled(), isTrue);
    expect(find.textContaining('The location log needs location permission'),
        findsNothing);
  });

  testWidgets(
      'enabling Location log when permission denied triggers system prompt popup and turns on if allowed',
      (tester) async {
    final profiles = await _profiles(masterOn: true, logOn: false);
    final loc = _FakeLocationService(
      hasBackground: false,
      checkPermissionResult: LocationPermission.denied,
      requestPermissionResult: LocationPermission.always,
    );

    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: profiles,
        api: _FakeApi(const []),
        locationService: loc,
      ),
    );

    await tester.tap(find.text('Location log'));
    await tester.pumpAndSettle();

    expect(loc.requestCalls, greaterThanOrEqualTo(1));
    expect(loc.openSettingsCalls, 0);
    expect(await profiles.locationLogEnabled(), isTrue);
    expect(find.textContaining('The location log needs location permission'),
        findsNothing);
  });

  testWidgets(
      'enabling Location log when prompt is denied keeps toggle off without dead-end toast',
      (tester) async {
    final profiles = await _profiles(masterOn: true, logOn: false);
    final loc = _FakeLocationService(
      hasBackground: false,
      checkPermissionResult: LocationPermission.denied,
      requestPermissionResult: LocationPermission.denied,
    );

    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: profiles,
        api: _FakeApi(const []),
        locationService: loc,
      ),
    );

    await tester.tap(find.text('Location log'));
    await tester.pumpAndSettle();

    expect(loc.requestCalls, 1);
    expect(loc.openSettingsCalls, 0);
    expect(await profiles.locationLogEnabled(), isFalse);
    expect(find.textContaining('The location log needs location permission'),
        findsNothing);
  });

  testWidgets(
      'enabling Location log when permanently denied opens app system settings directly',
      (tester) async {
    final profiles = await _profiles(masterOn: true, logOn: false);
    final loc = _FakeLocationService(
      hasBackground: false,
      checkPermissionResult: LocationPermission.deniedForever,
    );

    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: profiles,
        api: _FakeApi(const []),
        locationService: loc,
      ),
    );

    await tester.tap(find.text('Location log'));
    await tester.pumpAndSettle();

    // Cannot be prompted -> triggers openAppSettings without calling requestPermission
    expect(loc.requestCalls, 0);
    expect(loc.openSettingsCalls, 1);
    expect(await profiles.locationLogEnabled(), isFalse);
    expect(find.textContaining('The location log needs location permission'),
        findsNothing);
  });

  testWidgets(
      'returning from system settings with permission granted reconciles toggle and state to on',
      (tester) async {
    final profiles = await _profiles(masterOn: true, logOn: false);
    final loc = _FakeLocationService(
      hasBackground: false,
      checkPermissionResult: LocationPermission.deniedForever,
    );

    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: profiles,
        api: _FakeApi(const [
          LocationPattern(label: 'gym', placeKind: 'gym', count: 5),
        ]),
        locationService: loc,
      ),
    );

    // Tap Location log to open settings
    await tester.tap(find.text('Location log'));
    await tester.pumpAndSettle();
    expect(loc.openSettingsCalls, 1);
    expect(await profiles.locationLogEnabled(), isFalse);

    // User grants permission in system settings and returns
    loc.hasBackground = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(await profiles.locationLogEnabled(), isTrue);
    expect(find.text('gym'), findsOneWidget);
  });

  testWidgets(
      'returning from system settings without granting keeps toggle off',
      (tester) async {
    final profiles = await _profiles(masterOn: true, logOn: false);
    final loc = _FakeLocationService(
      hasBackground: false,
      checkPermissionResult: LocationPermission.deniedForever,
    );

    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: profiles,
        api: _FakeApi(const []),
        locationService: loc,
      ),
    );

    await tester.tap(find.text('Location log'));
    await tester.pumpAndSettle();
    expect(loc.openSettingsCalls, 1);

    // User returns without granting
    loc.hasBackground = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(await profiles.locationLogEnabled(), isFalse);
  });

  testWidgets(
      'resuming app when location permission was revoked outside app reconciles toggle to off',
      (tester) async {
    final profiles = await _profiles(masterOn: true, logOn: true);
    final loc = _FakeLocationService(hasBackground: false);

    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: profiles,
        api: _FakeApi(const []),
        locationService: loc,
      ),
    );
    await tester.pumpAndSettle();

    // Stored as true, but permission is missing on resume -> reconciles to false
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(await profiles.locationLogEnabled(), isFalse);
  });

  testWidgets('turning off Location log does not touch permission or settings',
      (tester) async {
    final profiles = await _profiles(masterOn: true, logOn: true);
    final loc = _FakeLocationService(hasBackground: true);

    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: profiles,
        api: _FakeApi(const []),
        locationService: loc,
      ),
    );

    await tester.tap(find.text('Location log'));
    await tester.pumpAndSettle();

    expect(await profiles.locationLogEnabled(), isFalse);
    expect(loc.requestCalls, 0);
    expect(loc.openSettingsCalls, 0);
  });
}
