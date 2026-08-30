/// Auth configuration constants.
///
/// The Google *server* (web) OAuth client id — needed by google_sign_in 7.x to
/// return an `idToken` for Firebase. This is not a secret: it already ships in
/// `android/app/google-services.json` and inside the built app.
class AuthConfig {
  const AuthConfig._();

  static const String googleServerClientId =
      '235381544962-e0ok0innn3o2ehmgsnh1ehbah5hec5ih.apps.googleusercontent.com';
}
