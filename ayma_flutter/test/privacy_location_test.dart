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
      'enabling Location log from never-asked state requests system popup and on first denial stays off with feedback',
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

    // From never-asked state, tapping ON must issue the system permission request (not skip to Settings)
    expect(loc.requestCalls, 1);
    expect(loc.openSettingsCalls, 0);
    expect(await profiles.locationLogEnabled(), isFalse);
    // On first denial, shows visible feedback instead of a silent no-op or dead-end toast
    expect(
      find.textContaining(
          "Location log needs location permission. Turn it on again when you're ready to allow it."),
      findsOneWidget,
    );
    expect(find.textContaining('The location log needs location permission'),
        findsNothing);
  });

  testWidgets(
      'enabling Location log when permanently denied shows tell dialog before opening settings',
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

    // Cannot be prompted -> shows tell dialog so user can read why before leaving
    expect(loc.requestCalls, 0);
    expect(loc.openSettingsCalls, 0);
    expect(find.textContaining('Location log needs location permission'),
        findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);

    // Confirm dialog -> opens app settings
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();

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

    // Tap Location log to open dialog
    await tester.tap(find.text('Location log'));
    await tester.pumpAndSettle();
    expect(loc.openSettingsCalls, 0);

    // Confirm dialog to open settings
    await tester.tap(find.text('Open Settings'));
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
    await tester.tap(find.text('Open Settings'));
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

  // --- NOTE 216 Leg f & NOTE 218: Date moments pending grant & tell -------

  testWidgets(
      'enabling Date moments when permission is promptable shows the system popup',
      (tester) async {
    final profiles = await _profiles(masterOn: true);
    final loc = _FakeLocationService(
      checkPermissionResult: LocationPermission.denied,
      // foreground (while-in-use) is enough for Date moments
      requestPermissionResult: LocationPermission.whileInUse,
    );

    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: profiles,
        api: _FakeApi(const []),
        locationService: loc,
      ),
    );

    await tester.tap(find.text('Date moments'));
    await tester.pumpAndSettle();

    expect(loc.requestCalls, greaterThanOrEqualTo(1)); // the popup was shown
    expect(loc.openSettingsCalls, 0);
    expect(await profiles.dateMomentsEnabled(), isTrue); // granted -> enabled
  });

  testWidgets(
      'enabling Date moments when permanently denied shows tell dialog before opening settings',
      (tester) async {
    final profiles = await _profiles(masterOn: true);
    final loc = _FakeLocationService(
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

    await tester.tap(find.text('Date moments'));
    await tester.pumpAndSettle();

    // Cannot be prompted -> shows tell dialog so user can read why before redirect
    expect(loc.requestCalls, 0);
    expect(loc.openSettingsCalls, 0);
    expect(find.textContaining('Date moments needs location permission'),
        findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);

    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();

    expect(loc.openSettingsCalls, 1);
    expect(await profiles.dateMomentsEnabled(), isFalse);
  });

  testWidgets(
      'enabling Date moments when the prompt is dismissed gives feedback and stays off',
      (tester) async {
    final profiles = await _profiles(masterOn: true);
    final loc = _FakeLocationService(
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

    await tester.tap(find.text('Date moments'));
    await tester.pumpAndSettle();

    expect(loc.requestCalls, 1); // the popup was shown
    expect(loc.openSettingsCalls, 0);
    expect(find.textContaining('Date moments needs location permission'),
        findsOneWidget); // feedback, never a silent no-op
    expect(await profiles.dateMomentsEnabled(), isFalse);
  });

  testWidgets(
      'denied-forever tell dialog Cancel button dismisses dialog and stays off without opening settings',
      (tester) async {
    final profiles = await _profiles(masterOn: true);
    final loc = _FakeLocationService(
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

    await tester.tap(find.text('Date moments'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Date moments needs location permission'),
        findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Date moments needs location permission'),
        findsNothing);
    expect(loc.openSettingsCalls, 0);
    expect(await profiles.dateMomentsEnabled(), isFalse);
  });

  testWidgets(
      'Date moments: denied-forever, tap ON, grant in Settings, return auto-applies Date moments ON without second tap',
      (tester) async {
    final profiles = await _profiles(masterOn: true);
    final loc = _FakeLocationService(
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

    // Tap Date moments ON -> opens tell dialog
    await tester.tap(find.text('Date moments'));
    await tester.pumpAndSettle();
    expect(loc.openSettingsCalls, 0);

    // Tap Open Settings -> settings redirect
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(loc.openSettingsCalls, 1);
    expect(await profiles.dateMomentsEnabled(), isFalse);

    // Grant location (while-in-use suffices for Date moments) in Settings and return
    loc.checkPermissionResult = LocationPermission.whileInUse;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(await profiles.dateMomentsEnabled(), isTrue);
  });

  testWidgets(
      'Date moments: denied-forever, tap ON, do NOT grant in Settings, return stays OFF',
      (tester) async {
    final profiles = await _profiles(masterOn: true);
    final loc = _FakeLocationService(
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

    await tester.tap(find.text('Date moments'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(loc.openSettingsCalls, 1);

    // Return without granting
    loc.checkPermissionResult = LocationPermission.deniedForever;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(await profiles.dateMomentsEnabled(), isFalse);
  });

  testWidgets(
      'Date moments: no pending tap -> resume reconcile changes nothing for Date moments',
      (tester) async {
    final profiles = await _profiles(masterOn: true);
    await profiles.setDateMoments(true);
    final loc = _FakeLocationService(
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
    await tester.pumpAndSettle();

    // No pending tap: resume reconcile leaves Date moments untouched
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(await profiles.dateMomentsEnabled(), isTrue);
  });

  testWidgets('turning off Date moments does not touch permission or settings',
      (tester) async {
    final profiles = await _profiles(masterOn: true);
    await profiles.setDateMoments(true);
    final loc = _FakeLocationService(
      checkPermissionResult: LocationPermission.whileInUse,
    );

    await _pump(
      tester,
      PrivacySettingsScreen(
        profileService: profiles,
        api: _FakeApi(const []),
        locationService: loc,
      ),
    );

    await tester.tap(find.text('Date moments'));
    await tester.pumpAndSettle();

    expect(await profiles.dateMomentsEnabled(), isFalse);
    expect(loc.requestCalls, 0);
    expect(loc.openSettingsCalls, 0);
  });

  testWidgets(
      'Location log routed to settings tells the user what is happening',
      (tester) async {
    final profiles = await _profiles(masterOn: true, logOn: false);
    final loc = _FakeLocationService(
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

    // User is shown why settings is opening before redirect
    expect(loc.openSettingsCalls, 0);
    expect(find.textContaining('Location log needs location permission'),
        findsOneWidget);

    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();

    expect(loc.openSettingsCalls, 1);
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
