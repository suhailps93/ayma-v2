import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/notification_prefs_screen.dart';
import 'package:ayma_flutter/screens/preboarding_flow_screen.dart';
import 'package:ayma_flutter/screens/profile_settings_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/notification_service.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Founder feedback item 14 (2026-11-06): when Ayma changes something on
/// screen — search radius, age range, the gender the user is interested
/// in — the visible screen must update in real time, as if a real user
/// made the change, with no navigate-away-and-back. These tests prove the
/// command/write → visible-control path for each screen whose state Ayma
/// drives through the profile / prefs docs or the app-command channel.

class _LiveProfileService extends ProfileService {
  _LiveProfileService(this._initial)
      : super(
            auth: MockFirebaseAuth(
                signedIn: true, mockUser: MockUser(uid: 'u1')));

  final ProfileData? _initial;
  final StreamController<ProfileData?> _ctrl =
      StreamController<ProfileData?>.broadcast();

  /// Simulates Ayma's backend tools writing the profile doc (the exact
  /// store `watchProfile` reads and her commands mutate).
  void emit(ProfileData d) => _ctrl.add(d);

  @override
  Future<ProfileData?> readProfile() async => _initial;

  @override
  Stream<ProfileData?> watchProfile() => _ctrl.stream;

  @override
  Future<void> updateStructuredFields({
    String? name,
    String? firstName,
    String? lastName,
    String? phone,
    DateTime? birthdate,
    String? gender,
    List<String>? interestedIn,
    String? location,
  }) async {}
}

ProfileData _profile({
  String gender = 'Man',
  List<String> interestedIn = const ['Women'],
  String location = 'Berlin',
  int? ageMin = 25,
  int? ageMax = 35,
  String distance = '25',
}) =>
    ProfileData(
      name: 'Sam',
      firstName: 'Samuel',
      lastName: 'Vale',
      phone: '+15551234567',
      birthdate: DateTime(1996, 5, 4),
      gender: gender,
      interestedIn: interestedIn,
      location: location,
      partnerAgeMin: ageMin,
      partnerAgeMax: ageMax,
      distancePreference: distance,
    );

class _LiveNotificationService extends NotificationService {
  _LiveNotificationService(Map<String, bool> initial)
      : _prefs = Map.of(initial),
        super(
            auth: MockFirebaseAuth(
                signedIn: true, mockUser: MockUser(uid: 'me')));

  final Map<String, bool> _prefs;
  final StreamController<Map<String, bool>> _ctrl =
      StreamController<Map<String, bool>>.broadcast();

  /// Simulates Ayma's server-side notification-pref command writing the
  /// prefs doc.
  void emit(Map<String, bool> p) => _ctrl.add(Map.of(p));

  @override
  Future<Map<String, bool>> readPrefs() async => Map.of(_prefs);

  @override
  Stream<Map<String, bool>> watchPrefs() => _ctrl.stream;

  @override
  Future<void> setPref(String category, bool enabled) async {
    _prefs[category] = enabled;
  }
}

ApiClient _exploreApi(void Function(String? q) onQuery) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/explore') {
        onQuery(req.url.queryParameters['q']);
        return http.Response(jsonEncode({'cards': const []}), 200);
      }
      return http.Response('no', 404);
    }),
  );
}

void main() {
  testWidgets(
      'Edit profile: Ayma changing age range, distance, gender and '
      'interested-in updates the visible controls with no navigation',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = _LiveProfileService(_profile());
    await tester.pumpWidget(
      MaterialApp(home: ProfileSettingsScreen(profileService: svc)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Partner age range: 25–35'), findsOneWidget);
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '25 miles'))
            .selected,
        isTrue);

    // Ayma's tools write the profile doc (age range + distance via
    // save_partner_preferences, gender/interested-in via set_profile_field).
    svc.emit(_profile(
      gender: 'Woman',
      interestedIn: const ['Men'],
      location: 'Paris',
      ageMin: 30,
      ageMax: 40,
      distance: '100',
    ));
    await tester.pumpAndSettle();

    // Same screen instance, no re-pump of the widget: everything moved.
    expect(find.text('Partner age range: 30–40'), findsOneWidget);
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '100 miles'))
            .selected,
        isTrue);
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Woman'))
            .selected,
        isTrue);
    expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'Men'))
            .selected,
        isTrue);
    expect(find.widgetWithText(TextField, 'Paris'), findsOneWidget);
  });

  testWidgets(
      'Edit profile: a field the user is editing keeps their value while '
      'other fields still update live', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = _LiveProfileService(_profile());
    await tester.pumpWidget(
      MaterialApp(home: ProfileSettingsScreen(profileService: svc)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Berlin'), 'Lisbon');
    await tester.pump();

    svc.emit(_profile(location: 'Paris', ageMin: 31, ageMax: 41));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Lisbon'), findsOneWidget);
    expect(find.text('Paris'), findsNothing);
    expect(find.text('Partner age range: 31–41'), findsOneWidget);
  });

  testWidgets(
      'Notification preferences: Ayma turning a category off moves the '
      'visible switch with no navigation', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final all = {for (final k in notificationCategories.keys) k: true};
    final svc = _LiveNotificationService(all);
    await tester.pumpWidget(
      MaterialApp(home: NotificationPrefsScreen(service: svc)),
    );
    await tester.pumpAndSettle();

    expect(
        tester
            .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'Direct messages'))
            .value,
        isTrue);

    svc.emit({...all, 'dm_message': false});
    await tester.pumpAndSettle();

    expect(
        tester
            .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'Direct messages'))
            .value,
        isFalse);
  });

  testWidgets(
      'Explore: a search_explore command lands on the already-open screen',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() {
      AppContext.instance.pendingExploreQuery = null;
      AppContext.instance.liveExploreQuery.value = null;
      AppContext.instance.clear();
    });
    AppContext.instance.clear();

    String? sentQuery;
    final api = _exploreApi((q) => sentQuery = q);
    await tester.pumpWidget(
      MaterialApp(home: ExploreScreen(apiClient: api)),
    );
    await tester.pumpAndSettle();

    // The app-command channel Ayma's search_explore tool drives.
    final commands = AppCommandService(navigate: (_) {}, go: (_) {});
    final ok = commands.handleCommand(
        {'action': 'search_explore', 'query': 'kayaking in Tahoe'});
    expect(ok, isTrue);
    await tester.pumpAndSettle();

    expect(find.text('kayaking in Tahoe'), findsOneWidget);
    expect(sentQuery, 'kayaking in Tahoe');
  });

  testWidgets(
      'Preboarding: Ayma-set partner age range and distance appear on the '
      'visible slider and chips', (tester) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = _LiveProfileService(null);
    await tester.pumpWidget(
      MaterialApp(home: PreboardingFlowScreen(profileService: svc)),
    );
    await tester.pumpAndSettle();

    svc.emit(_profile(
      gender: 'Woman',
      interestedIn: const ['Everyone'],
      location: 'Lisbon, Portugal',
      ageMin: 28,
      ageMax: 42,
      distance: '100',
    ));
    await tester.pumpAndSettle();

    expect(find.text('Partner age range: 28–42'), findsOneWidget);
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '100 miles'))
            .selected,
        isTrue);
  });
}
