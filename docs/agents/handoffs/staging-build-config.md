# Task Handoff: staging-build-config

**Task Name:** staging-build-config  
**Date:** 2026-10-31  
**Branch:** `feat/staging-build-config`  
**Author:** Claude-Bedrock  
**Reviewer/PM:** Astro (Muse) / Founder: Suhail  

---

## 1. What Was Done

1. **Configurable Staging Environment via `--dart-define=ENV=staging`**:
   - Updated `ayma_flutter/lib/env.dart` with environment selection constants:
     - `Env.prodApiBaseUrl`: `https://ayma-api-235381544962.us-central1.run.app` (production default).
     - `Env.stagingApiBaseUrl`: `https://ayma-api-staging.invalid` (clearly marked, non-routable `.invalid` placeholder for staging until Cloud Run staging is provisioned).
     - `Env.env`: reads compile-time `String.fromEnvironment('ENV', defaultValue: 'production')`.
     - `Env.isStaging`: boolean flag (`env == 'staging'`).
     - `Env.apiBaseUrl`: defaults to `isStaging ? stagingApiBaseUrl : prodApiBaseUrl`. Overridable explicitly at build time with `--dart-define=AYMA_API_BASE_URL=...`.
   - **Zero Regression on Production**: When `ENV` is unset, `env` defaults to `'production'`, `isStaging` is `false`, and `apiBaseUrl` defaults to the existing production URL. Nothing about production behavior changes.

2. **Visible STAGING Banner / Ribbon in App Shell**:
   - Created `ayma_flutter/lib/widgets/staging_banner.dart` (`StagingBanner`):
     - Renders a visible diagonal `Banner` widget with message `'STAGING'` at `BannerLocation.topEnd` in staging orange (`Color(0xFFE65100)`).
     - Does not alter layout dimensions or block hit tests; safely handles directionality (LTR/RTL).
     - When not in staging, returns `child` untouched with zero overhead.
     - Supports `enabled` override for testing.
   - Integrated `StagingBanner` into:
     - `MainShellScreen` (`ayma_flutter/lib/screens/main_shell_screen.dart`): The 4-tab main app shell (Ayma, Explore, Messages, Profile).
     - `NavBarShell` (`ayma_flutter/lib/widgets/nav_bar_shell.dart`): Persistent shell navigation wrapper for pushed screens.

3. **Documentation**:
   - Updated `docs/ARCHITECTURE.md` §12.1 (Environments) describing `--dart-define=ENV=staging`, the staging URL placeholder, and the visible banner ribbon.
   - Documented the exact staging APK build commands below.

---

## 2. Exact Staging APK Build Command

### Direct Flutter Build Command
To build a release APK for staging with the staging environment active:
```bash
cd ayma_flutter
flutter build apk --release \
  --dart-define=ENV=staging \
  --dart-define=APP_BUILD="$(git rev-parse --short HEAD) · staging"
```

### Using `scripts/build-apk.sh` (with Sentry + RevenueCat Test Store Key)
`scripts/build-apk.sh` passes extra arguments through to `flutter build apk`:
```bash
./scripts/build-apk.sh --release \
  --dart-define=ENV=staging \
  --dart-define=APP_BUILD="$(git rev-parse --short HEAD) · staging"
```

### With Explicit Custom Staging URL (if provisioned)
If testing against a custom backend URL while keeping the staging UI banner:
```bash
cd ayma_flutter
flutter build apk --release \
  --dart-define=ENV=staging \
  --dart-define=AYMA_API_BASE_URL=https://staging.api.ayma.ai
```

---

## 3. Files Changed

- `ayma_flutter/lib/env.dart`: Added `prodApiBaseUrl`, `stagingApiBaseUrl`, `env`, `isStaging`, and conditional `apiBaseUrl` default.
- `ayma_flutter/lib/widgets/staging_banner.dart`: Created reusable `StagingBanner` widget wrapping `Banner` with `STAGING` label.
- `ayma_flutter/lib/screens/main_shell_screen.dart`: Wrapped shell `Scaffold` in `StagingBanner` with optional `showStagingBanner` testing hook.
- `ayma_flutter/lib/widgets/nav_bar_shell.dart`: Wrapped pushed-screen shell in `StagingBanner` with optional `showStagingBanner` testing hook.
- `ayma_flutter/test/env_staging_test.dart`: Added test suite covering `Env` defaults, `StagingBanner`, `MainShellScreen`, and `NavBarShell` integration.
- `docs/ARCHITECTURE.md`: Documented staging environment support in §12.1.
- `docs/agents/handoffs/staging-build-config.md`: This handoff document.

---

## 4. Tests Run and Results

1. **Unit & Widget Tests (`ayma_flutter/test/env_staging_test.dart`)**:
   - Command: `flutter test test/env_staging_test.dart`
   - Result: **7/7 passed**.
     - `Env.prodApiBaseUrl` / `Env.stagingApiBaseUrl` constants verified.
     - Production remains default when `ENV` is unset.
     - `StagingBanner` enabled vs disabled rendering verified.
     - `MainShellScreen` staging banner visibility verified.
     - `NavBarShell` staging banner visibility verified.

2. **Shell Widget Tests (`ayma_flutter/test/main_shell_screen_test.dart` & `test/nav_bar_shell_test.dart`)**:
   - Command: `flutter test test/main_shell_screen_test.dart test/nav_bar_shell_test.dart`
   - Result: **15/15 passed**. No regression in existing navigation, tab switching, or popup behaviors.

3. **Layout Matrix Robustness Test (`ayma_flutter/test/layout_matrix_test.dart`)**:
   - Command: `flutter test test/layout_matrix_test.dart`
   - Result: **21/21 passed**. Verified that all routed screens, sheets, dialogs, and toasts render with zero overflows or layout violations.

4. **Flutter Static Analysis (`flutter analyze`)**:
   - Command: `flutter analyze`
   - Result: **No issues found** (0 warnings, 0 errors).

---

## 5. What Remains

- Once a dedicated Cloud Run staging service is deployed, update `Env.stagingApiBaseUrl` placeholder (`https://ayma-api-staging.invalid`) to the actual Cloud Run URL or pass `--dart-define=AYMA_API_BASE_URL=<staging-url>`.
- No remaining items for this task.
