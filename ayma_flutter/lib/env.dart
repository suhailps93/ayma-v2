/// Client environment config (ARCHITECTURE.md §1.7 step 1).
///
/// Only backend / LiveKit connection config lives here. Overridable at build
/// time with `--dart-define=AYMA_API_BASE_URL=...`.
class Env {
  const Env._();

  static const String apiBaseUrl = String.fromEnvironment(
    'AYMA_API_BASE_URL',
    defaultValue: 'https://ayma-api-235381544962.us-central1.run.app',
  );
}
