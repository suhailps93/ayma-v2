# Android build / sign / deploy runbook — Firebase App Distribution

How to ship the Ayma Flutter app (Android package **`com.ayma.ayma_flutter`**,
Firebase app id **`1:235381544962:android:99993490ed0aee69c4ef1b`**, Firebase
project **`ayma-ai`**) to the Pixel — and any other tester's phone — through CI,
with no local release tooling beyond `keytool`.

Companion to [`IOS_DEPLOY.md`](./IOS_DEPLOY.md). Both platforms are wired in the
repo-root [`codemagic.yaml`](../codemagic.yaml):

| Workflow | Instance | Output |
|---|---|---|
| `android-firebase` | Linux | signed release APK → **Firebase App Distribution** |
| `ios-testflight` | macOS | signed release IPA → **TestFlight** |

- **Backend is unaffected** — this is client-only.
- No Google Play Developer account ($25) is needed for App Distribution. You can
  add a `google_play` publish target later without touching the signing setup.

---

## 0. Happy path

1. **Firebase App Distribution** — enable it, make a tester group, join it. [§1](#1-firebase-app-distribution)
2. **CI service account** — a GCP service account with *Firebase App Distribution
   Admin*, JSON key downloaded. [§2](#2-ci-service-account)
3. **Upload keystore** — generate once with `keytool`, upload to Codemagic, back
   it up. [§3](#3-upload-keystore-release-signing)
4. **Codemagic env** — `firebase_credentials` group + the keystore reference. [§4](#4-codemagic-configuration)
5. **Push to `main`** → Codemagic runs `flutter analyze` + `flutter test`, builds
   a release APK, verifies it is release-signed, uploads to App Distribution
   (~5–10 min). Testers get an email / an "App Tester" notification.
6. Iterate: edit Dart → push → new build lands on every tester's phone.

First build number is Codemagic's `$PROJECT_BUILD_NUMBER` (auto-increments per
project); `versionName` comes from `pubspec.yaml` (`1.0.0`).

---

## 1. Firebase App Distribution

<https://console.firebase.google.com/project/ayma-ai/appdistribution>

1. **App Distribution → Get started.**
2. **Testers & Groups → Groups → New group.** Name it `testers` (this string is
   `FIREBASE_TESTER_GROUPS` in `codemagic.yaml` and the `groups:` entry under
   `publishing.firebase.android`). Add your Google account as a tester in that
   group. Add the iPad/other testers' Google accounts too.
3. On the **Pixel**: install **App Tester** from the Play Store
   (`com.google.firebase.appdistribution`), sign in with the tester account. The
   *first* build must be accepted from the invitation email link; after that new
   builds show up in App Tester automatically.

The Android app is already registered in `ayma-ai` (see
`android/app/google-services.json`, which is committed) — nothing to add there.

---

## 2. CI service account

App Distribution uploads from CI authenticate as a service account, not as you.

1. <https://console.cloud.google.com/iam-admin/serviceaccounts?project=ayma-ai>
   → **Create service account**.
   - Name: `codemagic-app-distribution`
   - Grant role: **Firebase App Distribution Admin**
     (`roles/firebaseappdistro.admin`). That is the only role it needs.
2. Open the new account → **Keys → Add key → Create new key → JSON → Create**.
   A `ayma-ai-xxxxxxxx.json` downloads. Treat it like a password.
   - It matches the repo's `*serviceAccount*.json` / `*-service-account*.json`
     gitignore globs, but **do not** put it in the repo at all — it goes only
     into Codemagic.

---

## 3. Upload keystore (release signing)

Flutter debug-signs `flutter run --release` by default. Firebase App
Distribution (and later Google Play) needs a stable **upload key**. Generate it
once on this Linux box — `keytool` ships with the JDK:

```bash
keytool -genkey -v -keystore ~/ayma-upload.jks -storetype JKS \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Answer the prompts; remember the **store password**, **key password**, and the
alias (`upload`).

> **Back up `~/ayma-upload.jks` and both passwords** (password manager + an
> offline copy). If you lose this key you cannot ship an update to the same app
> entry — Play would require a key reset, App Distribution a new app.

### How the repo consumes it

`android/app/build.gradle.kts` resolves signing material in this order:

1. **`ayma_flutter/android/key.properties`** (a sibling of `android/app/`, i.e.
   `rootProject.file("key.properties")`). Used for **local** release builds.
   Gitignored.
   ```properties
   storeFile=/home/suhailps/ayma-upload.jks
   storePassword=…
   keyAlias=upload
   keyPassword=…
   ```
   Then `flutter build apk --release` locally is properly signed.
2. **`CM_KEYSTORE_PATH` / `CM_KEYSTORE_PASSWORD` / `CM_KEY_ALIAS` /
   `CM_KEY_PASSWORD`** — environment variables Codemagic injects when a
   workflow's `android_signing:` list names an uploaded keystore. No
   `key.properties` file needed on CI.
3. **Neither present** → falls back to debug keys, so a teammate can still
   `flutter run --release` without the keystore.

### Upload to Codemagic

Codemagic → your app → **app settings → Code signing identities → Android
keystores → Add keystore**:

- Upload `~/ayma-upload.jks`
- Keystore password, key alias (`upload`), key password
- **Reference name: `ayma_upload_keystore`** — must equal the entry under
  `environment.android_signing` in `codemagic.yaml`.

The build step in `codemagic.yaml` runs `apksigner verify --print-certs` on the
resulting APK and **fails the build** if it came out `CN=Android Debug` (i.e. the
env vars never reached Gradle).

---

## 4. Codemagic configuration

Codemagic → your app → **app settings → Environment variables**. Create group
**`firebase_credentials`** (referenced by `environment.groups` in the
`android-firebase` workflow):

| Variable | Kind | Value |
|---|---|---|
| `FIREBASE_SERVICE_ACCOUNT` | **secure** | the entire contents of the JSON from [§2](#2-ci-service-account) |

`FIREBASE_ANDROID_APP_ID` and `FIREBASE_TESTER_GROUPS` are already set as plain
`vars:` in `codemagic.yaml` — change them there, not in the UI, if they differ.

### `codemagic.yaml` TODOs to close

- `environment.android_signing` → `ayma_upload_keystore` (keystore reference from §3)
- `FIREBASE_TESTER_GROUPS` and the `publishing.firebase.android.groups` entry →
  your real group name from [§1](#1-firebase-app-distribution) (both say `testers`)
- `publishing.email.recipients` → your address, or delete the `email:` block

---

## 5. Run it

- **Automatic:** push to `main`. The `android-firebase` and `ios-testflight`
  workflows both start. Each push spends minutes on both — to run Android only on
  demand, comment out the `triggering:` block in the `android-firebase` workflow
  and use **Codemagic → Start new build → android-firebase**.
- **Watch:** Codemagic build log. Failure points, in order: `flutter test`
  (fix the test), the debug-signed guard (keystore env vars — §3), the Firebase
  upload (`FIREBASE_SERVICE_ACCOUNT` JSON or the role in §2).
- **On success:** the APK is attached to the build page as an artifact *and*
  pushed to App Distribution. Testers in the `testers` group get it.

---

## 6. Local release build (no CI)

```bash
# one-time: create android/key.properties as in §3
cd ayma_flutter
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Without `android/key.properties` this still succeeds but produces a
**debug-signed** APK (fine for `adb install`, not for distribution).

---

## 7. Adding Google Play later

Nothing here blocks it. When you want a Play track:

1. Google Play Console → pay $25 → create the app for `com.ayma.ayma_flutter`.
2. Enrol the app in **Play App Signing** (Google holds the app signing key; your
   `~/ayma-upload.jks` stays the upload key — no regen needed).
3. GCP service account with the Play Developer API + an invite in Play Console.
4. Add a `google_play` block to the `android-firebase` workflow's `publishing:`
   (or a separate `android-play` workflow) and build an `.aab`
   (`flutter build appbundle --release`) instead of / alongside the APK.
