import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Apple only ever hands us `givenName`/`familyName` on the very first
/// authorization for a given Apple ID + app — captured here (§ signInWithApple)
/// or it's gone for good. This exercises that capture logic directly, since
/// the real credential only ever comes from Apple's native platform channel,
/// which these tests can't invoke.
class _RecordingProfileService extends ProfileService {
  _RecordingProfileService(FirebaseAuth auth) : super(auth: auth);

  int calls = 0;
  String? firstName;
  String? lastName;

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
  }) async {
    calls++;
    this.firstName = firstName;
    this.lastName = lastName;
  }
}

AuthorizationCredentialAppleID _credential({String? given, String? family}) {
  return AuthorizationCredentialAppleID(
    userIdentifier: 'apple-uid',
    givenName: given,
    familyName: family,
    authorizationCode: 'auth-code',
    email: null,
    identityToken: 'id-token',
    state: null,
  );
}

void main() {
  group('AuthService.captureAppleName', () {
    test('a real first-time name sets displayName and prefills the profile',
        () async {
      final auth =
          MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1'));
      final profile = _RecordingProfileService(auth);
      final service = AuthService(auth: auth, profileService: profile);

      await service.captureAppleName(
        _credential(given: 'Jamie', family: 'Rivera'),
        auth.currentUser,
      );

      expect(auth.currentUser!.displayName, 'Jamie Rivera');
      expect(profile.calls, 1);
      expect(profile.firstName, 'Jamie');
      expect(profile.lastName, 'Rivera');
    });

    test('null name fields (repeat sign-in or hidden name) are a no-op',
        () async {
      final auth = MockFirebaseAuth(
          signedIn: true, mockUser: MockUser(uid: 'u2', displayName: null));
      final profile = _RecordingProfileService(auth);
      final service = AuthService(auth: auth, profileService: profile);

      await service.captureAppleName(_credential(), auth.currentUser);

      expect(auth.currentUser!.displayName, isNull);
      expect(profile.calls, 0);
    });

    test('an already-set displayName is left alone', () async {
      final auth = MockFirebaseAuth(
          signedIn: true,
          mockUser: MockUser(uid: 'u3', displayName: 'Existing Name'));
      final profile = _RecordingProfileService(auth);
      final service = AuthService(auth: auth, profileService: profile);

      await service.captureAppleName(
        _credential(given: 'Jamie', family: 'Rivera'),
        auth.currentUser,
      );

      expect(auth.currentUser!.displayName, 'Existing Name');
      // The structured profile fields still get the belt-and-suspenders
      // write, independent of whatever the Firebase displayName holds.
      expect(profile.calls, 1);
      expect(profile.firstName, 'Jamie');
    });

    test('a given name with no family name still writes what we have',
        () async {
      final auth =
          MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u4'));
      final profile = _RecordingProfileService(auth);
      final service = AuthService(auth: auth, profileService: profile);

      await service.captureAppleName(
        _credential(given: 'Jamie', family: null),
        auth.currentUser,
      );

      expect(auth.currentUser!.displayName, 'Jamie');
      expect(profile.firstName, 'Jamie');
      expect(profile.lastName, isNull);
    });

    test('a null user (defensive) never throws', () async {
      final auth =
          MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u5'));
      final profile = _RecordingProfileService(auth);
      final service = AuthService(auth: auth, profileService: profile);

      await service.captureAppleName(
        _credential(given: 'Jamie', family: 'Rivera'),
        null,
      );

      expect(profile.calls, 1);
      expect(profile.firstName, 'Jamie');
    });
  });
}
