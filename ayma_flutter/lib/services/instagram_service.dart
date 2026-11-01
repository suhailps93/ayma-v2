import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'api_client.dart';

/// Backs the Instagram connect screen: connect/disconnect round trip against
/// the already-working `/instagram/*` endpoints (`instagram.py`) — this
/// service and `instagram_screen.dart` were the missing piece, since nothing
/// in the app ever called `/instagram/auth-url` through to a finished
/// connect before this.
///
/// Unlike Google, there is no `/instagram/status` endpoint. Status is read
/// directly off `users/{uid}.instagram_access_token` instead — the same
/// field Firestore's `allow read: if isOwner(uid)` rule already exposes to
/// the owning client (see the flagged, deliberately out-of-scope
/// token-storage note in `google_account.py`'s module docstring / §9.2 of
/// ARCHITECTURE.md). This only checks whether the field is set; it never
/// reads the token value out for display or logging.
class InstagramService {
  InstagramService({ApiClient? api, FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _apiOverride = api,
        _authOverride = auth,
        _fsOverride = firestore;

  final ApiClient? _apiOverride;
  final FirebaseAuth? _authOverride;
  final FirebaseFirestore? _fsOverride;

  late final ApiClient _api = _apiOverride ?? ApiClient();
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;
  FirebaseFirestore get _db => _fsOverride ?? FirebaseFirestore.instance;

  String get _uid {
    final u = _auth.currentUser?.uid;
    if (u == null) throw StateError('No signed-in user.');
    return u;
  }

  Future<String> authUrl() => _api.instagramAuthUrl();

  /// Exchanges the OAuth `code`; returns the number of photos imported.
  Future<int> connect(String code) => _api.instagramConnect(code);

  Future<void> disconnect() => _api.instagramDisconnect();

  /// Whether an Instagram account is currently connected.
  Future<bool> status() async {
    final snap = await _db.doc('users/$_uid').get().timeout(kInteractiveTimeout);
    final token = snap.data()?['instagram_access_token'] as String?;
    return token != null && token.isNotEmpty;
  }

  // -- "Sign in with Instagram" (new) — reachable before any Firebase auth
  // exists, unlike everything above. Proxies straight onto the matching
  // unauthenticated `ApiClient` calls.

  /// `GET /instagram/signin-auth-url` — the URL to open to authorise.
  Future<String> signinAuthUrl() => _api.instagramSigninAuthUrl();

  /// `POST /instagram/signin` — exchange the OAuth `code` for a Firebase
  /// custom token (and whether this created a brand-new account).
  Future<InstagramSigninResult> signin(String code) =>
      _api.instagramSignin(code);
}
