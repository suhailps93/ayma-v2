import 'dart:convert';

import 'package:ayma_flutter/screens/settings_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/theme_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Always "captures" the same file — stands in for the front-camera picker.
class _FakeImagePicker extends ImagePicker {
  int calls = 0;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    calls++;
    return XFile('selfie.jpg');
  }
}

class _FakeProfiles extends ProfileService {
  _FakeProfiles({this.uploadError})
      : super(
            auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')));

  /// When set, `uploadVerificationSelfie` throws this — a hard failure
  /// (storage/network), distinct from a rejected photo.
  final Object? uploadError;
  int uploadCalls = 0;

  @override
  Stream<bool> watchAiAvatar() => Stream.value(true);

  @override
  Stream<bool> watchPaused() => Stream.value(false);

  @override
  Future<String> uploadVerificationSelfie(file) async {
    uploadCalls++;
    if (uploadError != null) throw uploadError!;
    return 'verification/me/selfie.jpg';
  }
}

ApiClient _api({int verifyStatusCode = 200, Map<String, dynamic>? verifyBody}) {
  final mock = MockClient((req) async {
    if (req.url.path == '/verification/status') {
      return http.Response(jsonEncode({'verified': false}), 200);
    }
    if (req.url.path == '/verification/selfie') {
      return http.Response(
        jsonEncode(verifyBody ?? {'verified': true}),
        verifyStatusCode,
      );
    }
    return http.Response(jsonEncode({'ok': true}), 200);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

Widget _host(ProfileService p, ApiClient a, ImagePicker picker) => MaterialApp(
      theme: AymaTheme.light,
      home: SettingsScreen(
        controller: ThemeController(initial: ThemeMode.dark),
        profileService: p,
        api: a,
        imagePicker: picker,
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'a hard verify failure offers Retry instead of the raw exception',
      (tester) async {
    final profiles = _FakeProfiles(uploadError: Exception(
        '[firebase_storage/unauthorized] User is not authorized'));
    final picker = _FakeImagePicker();
    await tester.pumpWidget(_host(profiles, _api(), picker));
    await tester.pumpAndSettle();

    // The Animation section above pushes this row below the fold now.
    await tester.scrollUntilVisible(find.text('Verify your face'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verify your face'));
    await tester.pumpAndSettle();

    // Never the raw exception text.
    expect(find.textContaining('firebase_storage'), findsNothing);
    expect(find.text("Couldn't verify that photo — try again."),
        findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);

    // Tapping Retry re-invokes the capture flow.
    expect(picker.calls, 1);
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pump();
    expect(picker.calls, 2);
  });

  testWidgets('a moderation-rejected selfie also offers Retry', (tester) async {
    final profiles = _FakeProfiles();
    final picker = _FakeImagePicker();
    await tester.pumpWidget(_host(
      profiles,
      _api(verifyBody: {
        'verified': false,
        'moderation_status': 'flagged',
        'reason': 'no face detected',
      }),
      picker,
    ));
    await tester.pumpAndSettle();

    // The Animation section above pushes this row below the fold now.
    await tester.scrollUntilVisible(find.text('Verify your face'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verify your face'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining("That photo couldn't be verified"),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
  });

  testWidgets('a successful verify shows no Retry and flips the badge',
      (tester) async {
    final profiles = _FakeProfiles();
    final picker = _FakeImagePicker();
    await tester.pumpWidget(_host(profiles, _api(), picker));
    await tester.pumpAndSettle();

    // The Animation section above pushes this row below the fold now.
    await tester.scrollUntilVisible(find.text('Verify your face'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verify your face'));
    await tester.pumpAndSettle();

    expect(find.text("You're verified."), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
    expect(find.text('Face verified'), findsOneWidget);
  });
}
