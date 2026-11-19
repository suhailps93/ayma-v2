import 'package:firebase_core/firebase_core.dart';

import '../firebase_options.dart';

/// Detects a mis-built APK whose NATIVE Firebase config disagrees with the
/// Dart one, so the app signs in but every authed request is rejected (401).
///
/// On Android the google-services resources baked into the APK auto-create the
/// `[DEFAULT]` FirebaseApp (via `FirebaseInitProvider`) BEFORE any Dart runs.
/// `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`
/// then finds that default app already present and returns it unchanged — the
/// Dart `options` are NOT applied to an existing default app. So every ID token
/// is minted against the NATIVE project. If that project is not the one the
/// configured API base accepts — e.g. a staging build (`FB_PROJECT_ID`
/// dart-define = ayma-staging, API base = staging) left on the PROD
/// `google-services.json` (project ayma-ai) — the token's `aud`/`iss` are for
/// the wrong project and the backend returns 401 on `/bootstrap`, `/story`,
/// every authed call. The splash then bounces the user through sign-in, which
/// re-mints the same wrong-project token: an endless sign-in loop with no
/// honest signal (Scout NOTE 263).
///
/// A correctly built APK keeps both axes on one project (store/prod builds are
/// single-project; `scripts/build-apk.sh --staging` swaps the native config and
/// injects the matching dart-defines), so the two project ids are equal and
/// this guard is silent. When they differ the app is un-usable regardless of
/// what the user does, so the right behaviour — per AGENTS.md ("show an honest
/// error, never a silent hang / 401") — is a clear, blocking diagnostic at
/// startup instead of a silent loop.
class FirebaseConfigGuard {
  FirebaseConfigGuard._();

  static final FirebaseConfigGuard instance = FirebaseConfigGuard._();

  /// A human-readable diagnostic when the effective (native) and intended
  /// (Dart) Firebase projects disagree, else `null`. Set once at startup (N7)
  /// and read by the splash before any authed call. Resettable for tests.
  String? mismatch;

  /// Compares the effective (native `[DEFAULT]` app) project against the
  /// intended (Dart `DefaultFirebaseOptions`) project and stores the
  /// diagnostic. Never throws: if Firebase is not initialized the projects
  /// cannot be judged, so it leaves [mismatch] null and lets the normal flow
  /// (with its own error handling) proceed.
  void evaluate() {
    try {
      mismatch = firebaseProjectMismatchMessage(
        effectiveProjectId: Firebase.app().options.projectId,
        intendedProjectId: DefaultFirebaseOptions.currentPlatform.projectId,
      );
    } catch (_) {
      mismatch = null;
    }
  }

  /// Test seam — clears any recorded mismatch between cases.
  void resetForTest() {
    mismatch = null;
  }
}

/// Pure check: returns `null` when the two Firebase project ids match (the only
/// healthy state), else an honest, actionable diagnostic. An empty id on either
/// side yields `null` — an unknown project must never be reported as a
/// mismatch, so a config we cannot read can't produce a false positive.
String? firebaseProjectMismatchMessage({
  required String effectiveProjectId,
  required String intendedProjectId,
}) {
  final effective = effectiveProjectId.trim();
  final intended = intendedProjectId.trim();
  if (effective.isEmpty || intended.isEmpty) return null;
  if (effective == intended) return null;
  return 'This build is misconfigured: its Firebase project is "$effective" '
      'but it was built for "$intended". Sign-in works, but every request is '
      'rejected (401). Reinstall a build made with scripts/build-apk.sh — its '
      '--staging flag keeps the native and Dart Firebase configs on one '
      'project.';
}
