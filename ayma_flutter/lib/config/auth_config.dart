/// Auth configuration constants.
///
/// The Google *server* (web) OAuth client id — needed by google_sign_in 7.x to
/// return an `idToken` for Firebase. This is not a secret: it already ships in
/// `android/app/google-services.json` and inside the built app.
class AuthConfig {
  const AuthConfig._();

  // The Google Sign-In server (web) OAuth client id. Overridable at build time
  // with --dart-define=GOOGLE_SERVER_CLIENT_ID=... so a staging build uses the
  // ayma-staging web client; unset, it defaults to the prod (ayma-ai) client so
  // prod/store builds are unchanged. A staging build MUST override this — using
  // prod's client id mints a Google token for the wrong Firebase project, which
  // ayma-staging rejects (sign-in "succeeds" at the picker, then every backend
  // call is 401 "Not signed in"). scripts/build-apk.sh --staging sets it from
  // google-services.staging.json's web oauth_client. See docs/STAGING.md.
  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue:
        '235381544962-e0ok0innn3o2ehmgsnh1ehbah5hec5ih.apps.googleusercontent.com',
  );
}
