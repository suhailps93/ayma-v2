import 'package:flutter/foundation.dart';

/// Compile-time gate for the hidden Developer mode.
///
/// Baked in at build time from `--dart-define=ENABLE_DEV_MODE=true`. It
/// defaults to **false** (fail-safe), so any build that does not explicitly
/// opt in — every customer / store release (Codemagic, Play) — ships with dev
/// mode completely unreachable: the seven-tap (and long-press) version gesture
/// is a no-op, the developer password prompt never appears, and the
/// `/settings/developer` route and the dev-only routes behind it
/// (Ayma's notes, feedback triage) are never registered.
///
/// Internal / development APKs opt in by passing
/// `--dart-define=ENABLE_DEV_MODE=true` — wired into `scripts/build-apk.sh`.
const bool kDevModeEnabled =
    bool.fromEnvironment('ENABLE_DEV_MODE', defaultValue: false);

/// Whether developer mode is available in this run.
///
/// Reads the compile-time [kDevModeEnabled] by default. Everything dev-related
/// gates on this single getter so tests can flip it through
/// [debugDevModeOverride] — a `const bool.fromEnvironment` cannot be toggled at
/// runtime.
bool get devModeEnabled => debugDevModeOverride ?? kDevModeEnabled;

/// Test-only override for [devModeEnabled]; `null` falls back to the compiled
/// [kDevModeEnabled]. Reset to `null` in `tearDown`.
@visibleForTesting
bool? debugDevModeOverride;
