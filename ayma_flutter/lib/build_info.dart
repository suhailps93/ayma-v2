/// A human-readable build stamp shown at the bottom of Settings so it's obvious
/// whether a device is running the latest build.
///
/// Set at build time with `--dart-define=APP_BUILD="1.0.0 · abc1234 · date"`.
/// Falls back to "dev build" for a plain `flutter run`.
const String appBuildTag =
    String.fromEnvironment('APP_BUILD', defaultValue: 'dev build');
