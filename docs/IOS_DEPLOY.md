# iOS build / sign / deploy runbook — no Mac

How to ship the Ayma Flutter app (`ios/` bundle id **`com.ayma.aymaFlutter`**) to
an iPhone and an iPad when you own **no Mac** — only the two iOS devices.

Everything below is done from a browser + this Linux repo + a CI service. You
never run `xcodebuild`, `security`, `fastlane`, or touch a Keychain locally.

> Android's equivalent (release signing + Firebase App Distribution via the same
> `codemagic.yaml`) is in [`ANDROID_DEPLOY.md`](./ANDROID_DEPLOY.md).

- **Backend is unaffected.** This is client-only; Cloud Run / Firestore stay as-is.
- **Android is unaffected.** No Android file changes.
- The recommended path is **Codemagic** (Flutter-first, 500 free macOS-M2
  min/month, web UI, automatic signing + TestFlight publish). Rationale and
  alternatives are in [§7](#7-ci-options-compared).

---

## 0. The 5–8 step happy path

1. **Join the Apple Developer Program** ($99/yr) — [§1](#1-apple-developer-program-99yr).
2. **Apple Developer portal** (web): create the App ID `com.ayma.aymaFlutter`
   with **Push Notifications** + **Sign In with Apple** capabilities; create an
   **APNs Auth Key** (`.p8`); create an **App Store Connect API key** (`.p8`).
   — [§2](#2-apple-developer-portal-web-only), [§4](#4-app-store-connect-web-only).
3. **App Store Connect** (web): create the app record for
   `com.ayma.aymaFlutter`; add your Apple ID + a second Apple ID (or the same
   one) so the iPhone and iPad can be **internal TestFlight testers**.
   — [§4](#4-app-store-connect-web-only).
4. **Firebase console** (web): the `ayma-ai` project **already has an iOS app**
   registered (see `lib/firebase_options.dart`) — just **download
   `GoogleService-Info.plist`** and add it to the repo at
   `ios/Runner/GoogleService-Info.plist`; upload the **APNs Auth Key** to
   Firebase → Cloud Messaging. — [§5](#5-firebase-ios-setup-web--linux).
5. **Codemagic** (web): connect the repo, add the **App Store Connect API key**
   integration, create the `appstore_credentials` env-var group, fill the
   `TODO`s in `codemagic.yaml`. — [§6](#6-codemagic-setup), [§8](#8-what-the-ci-needs-secrets-checklist).
6. **Push to `main`** → Codemagic builds + signs + uploads to TestFlight
   (~10–20 min). Codemagic's `fetch-signing-files --create` makes the
   distribution certificate + provisioning profile on first run — you never
   generate them by hand.
7. **TestFlight app on the iPhone/iPad** → install the build. Internal testers
   get it in minutes with **no App Review**.
8. Iterate: edit Dart → push → wait for the CI build → new TestFlight build
   appears on both devices. There is **no hot reload / simulator** without macOS
   (see [§9](#9-the-devtest-loop-with-no-mac)).

Realistic first-time cost: **$99** (Apple, annual) + **$0** CI (fits the
Codemagic free tier for a while) + **~4–8 hours** of console wrangling and
CI-config iteration the first time, then ~15–20 min per build after that.

---

## 1. Apple Developer Program ($99/yr)

Enroll at <https://developer.apple.com/programs/enroll/>. Individual enrollment
is fine. Payment + identity verification can take anywhere from minutes to a
couple of days.

What the paid membership unlocks that you cannot do otherwise:

| Capability | Free Apple ID | Paid ($99/yr) |
|---|---|---|
| Install your own build on a device | 7-day cert, 3 apps, manual re-sign weekly | Yes, 1-year profiles |
| **TestFlight** (internal + external testers) | No | **Yes** |
| **Push notifications / APNs** (FCM needs this) | No | **Yes** |
| **Sign in with Apple** capability | No | **Yes** |
| App Store Connect app record + API keys | No | **Yes** |
| App Store submission | No | Yes |

Because the app uses `firebase_messaging` (push) and `sign_in_with_apple`, and
because a 7-day free cert would need re-signing on a Mac you don't have, **the
paid program is mandatory** for this project.

Everything in the sections below is **web portal or CI only** — no local Apple
tooling.

---

## 2. Apple Developer portal (web only)

<https://developer.apple.com/account/resources>

### 2.1 App ID (Identifier)

Identifiers → **+** → App IDs → App.

- Description: `Ayma Flutter`
- Bundle ID: **Explicit** → `com.ayma.aymaFlutter` (must match
  `PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj/project.pbxproj` and
  `iosBundleId` in `lib/firebase_options.dart` — both already say
  `com.ayma.aymaFlutter`).
- Capabilities — tick:
  - **Push Notifications**
  - **Sign In with Apple** (leave it as the primary App ID; "Edit" → default)
- Leave the rest unticked (the app needs nothing else — no HealthKit, no
  App Groups, no associated domains).

> The repo's new `ios/Runner/Runner.entitlements` declares `aps-environment` and
> `com.apple.developer.applesignin`. Those entitlements only work if the two
> capabilities above are enabled on this App ID. If you enable them *after*
> a provisioning profile already exists, regenerate the profile (Codemagic's
> `--create` handles this, or delete the profile and let it re-fetch).

### 2a. App ID for the Notification Service Extension

DM pushes show the **sender's avatar** on the lock screen via a Notification
Service Extension (new target `NotificationServiceExtension`, bundle id
**`com.ayma.aymaFlutter.NotificationServiceExtension`**; see
`docs/ARCHITECTURE.md` §7.10 and `ios/NotificationServiceExtension/`). The
extension is a second signed binary, so it needs its own **App ID** and
**provisioning profile**:

- Identifiers → **+** → App IDs → App → Bundle ID **Explicit** →
  `com.ayma.aymaFlutter.NotificationServiceExtension`, description
  `Ayma Notification Service Extension`. **No capabilities needed** (the
  extension uses no App Group, no push entitlement of its own — it only enriches
  an already-delivered alert).
- `codemagic.yaml`'s signing step now runs a **second**
  `app-store-connect fetch-signing-files "$BUNDLE_ID.NotificationServiceExtension"
  --type IOS_APP_STORE --create`, which registers this App ID and makes its
  profile on the first run. If that step fails with "no matching profiles",
  create the App ID by hand as above and re-run.
- This target rides the next **fresh iOS build** only; it is not part of any
  Android/APK build and does not affect the backend.

### 2.2 APNs Auth Key (for FCM push) — **.p8, token-based**

Keys → **+** → tick **Apple Push Notifications service (APNs)** → Register.

- Download the **`AuthKey_XXXXXXXXXX.p8`** — **you can only download it once.**
- Note the **Key ID** (the `XXXXXXXXXX`) and your **Team ID**
  (top-right of the portal, 10 chars).
- One APNs key works for every app under the team and for both the sandbox and
  production APNs environments. This file goes to **Firebase**, not to Codemagic
  ([§5.3](#53-apns-key--firebase)).

### 2.3 Certificates / provisioning profiles — **let CI create them**

You do **not** create these by hand. Codemagic's
`app-store-connect fetch-signing-files "$BUNDLE_ID" --type IOS_APP_STORE --create`
(already in `codemagic.yaml`) will, on first run:

1. Create an **iOS Distribution** signing certificate for the team (stored by
   Codemagic; reused on later builds).
2. Create an **App Store** provisioning profile bound to the App ID above.
3. Install both into the ephemeral build Keychain, then discard.

This is the "the CI's built-in automatic signing" model — nothing lands on your
machine.

**`fastlane match` alternative.** If you'd rather own the certs in a private Git
repo: `match` stores an encrypted distribution cert + profiles in a repo you
control, and any CI (Codemagic, GitHub Actions, Bitrise) can `match appstore` to
fetch them. It still needs one machine to *create* the cert the first time —
that machine can be a Linux box, because `match` can generate the cert via the
App Store Connect API without a Keychain (`match --api-key-path ...`). Use this
only if you have a reason to pin the identity; for one app the CI-managed path
is less moving parts.

**CSR-on-Linux fallback** (only if a tool insists on manual cert creation):

```bash
openssl genrsa -out ios_distribution.key 2048
openssl req -new -key ios_distribution.key -out ios_distribution.csr \
  -subj "/emailAddress=suhailps@gmail.com/CN=Ayma iOS Distribution/C=IN"
# Upload ios_distribution.csr at: Certificates → + → Apple Distribution
# Download the resulting .cer, then convert to the .p12 that CIs want:
openssl x509 -in distribution.cer -inform DER -out distribution.pem -outform PEM
openssl pkcs12 -export -inkey ios_distribution.key -in distribution.pem \
  -out distribution.p12 -name "Ayma iOS Distribution"
```

The `.p12` + its export password is what you'd paste into a CI that does manual
signing. **You should not need this with Codemagic.**

---

## 3. What changed in the repo (scaffold already applied)

| File | Change | Why |
|---|---|---|
| `ios/Runner/Info.plist` | Added `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription` (image_picker); `UIBackgroundModes → audio` (livekit voice keeps the audio session alive when locked/backgrounded); `CFBundleURLTypes` with the reversed Google OAuth client id (google_sign_in callback); tightened the existing mic/location strings. | App Review rejects missing purpose strings; Google sign-in silently fails without the URL type; a locked-screen voice call is killed without the `audio` background mode. |
| `ios/Runner/Runner.entitlements` | **New.** `aps-environment` (push) + `com.apple.developer.applesignin` (Sign in with Apple). | Required entitlements for `firebase_messaging` and `sign_in_with_apple`. |
| `ios/Runner.xcodeproj/project.pbxproj` | `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` on the Runner target's Debug/Release/Profile configs; added the entitlements file reference to the Runner group; bumped `IPHONEOS_DEPLOYMENT_TARGET` 12.0 → **15.0** on all three project configs. | Wires the entitlements into every build; 15.0 is the floor the Firebase pods demand (below). |
| `ios/Podfile` | **New.** `platform :ios, '15.0'` + a `post_install` that forces every pod to 15.0. | There was no Podfile. `firebase_core 4.14 / firebase_auth 6.6 / cloud_firestore 6.9 / firebase_storage 13.5 / firebase_messaging 16.6` pods all declare `ios.deployment_target = '15.0'`. That is the hard minimum; livekit wants 13, everything else ≤12. |
| `ios/Flutter/AppFrameworkInfo.plist` | `MinimumOSVersion` 12.0 → 15.0. | Keep in sync with the deployment target. |
| `codemagic.yaml` (repo root) | **New.** `ios-testflight` workflow: `working_directory: ayma_flutter`, `flutter pub get` → `pod install` → automatic signing → `flutter build ipa` → publish to TestFlight. | The CI definition. `TODO`s mark the values only your Apple/Codemagic consoles produce. |

**`AppDelegate.swift` was deliberately left unchanged.** `firebase_messaging`
16.x uses AppDelegate method **swizzling by default** — it forwards the APNs
device token and routes notification callbacks with no code in
`AppDelegate.swift` beyond the existing `GeneratedPluginRegistrant.register`.
Only add code there if you later set
`FirebaseAppDelegateProxyEnabled = NO` in `Info.plist` (you have not), or add a
`@pragma` background isolate handler. *Confirm against the plugin version you
ship — see [§12](#12-things-to-verify--currently-uncertain).*

Minimum iOS after this change: **iOS 15.0** (covers iPhone 6s and later / all
iPads that run iPadOS 15+, i.e. effectively every device in use).

---

## 4. App Store Connect (web only)

<https://appstoreconnect.apple.com>

### 4.1 Create the app record

My Apps → **+** → New App.

- Platform: iOS
- Name: `Ayma` (must be globally unique on the App Store; pick a fallback if
  taken)
- Primary language: English
- Bundle ID: select **`com.ayma.aymaFlutter`** (appears once [§2.1](#21-app-id-identifier)
  is done)
- SKU: any stable string, e.g. `ayma-ios-001`
- User access: Full

After creation, open **App Information → General Information** and copy the
numeric **"Apple ID"** (a ~10-digit number, *not* the bundle id). That is
`APP_STORE_APP_ID` for `codemagic.yaml`.

### 4.2 App Store Connect API key (for CI upload + signing)

Users and Access → **Integrations** tab → App Store Connect API → **Team Keys**
→ **+**.

- Access role: **App Manager** (enough to upload builds and manage signing;
  "Admin" also works).
- Download **`AuthKey_YYYYYYYYYY.p8`** — **one-time download.**
- Record: **Issuer ID** (UUID, shown once at the top of the Keys page) and the
  **Key ID** (`YYYYYYYYYY`).

This is a **different** `.p8` from the APNs key in [§2.2](#22-apns-auth-key-for-fcm-push--p8-token-based).
Keep them straight:

| `.p8` | Purpose | Goes to |
|---|---|---|
| `AuthKey_<APNs KeyID>.p8` | Send push via APNs | **Firebase** → Cloud Messaging |
| `AuthKey_<ASC KeyID>.p8` + Issuer ID | CI signs + uploads builds | **Codemagic** integration |

### 4.3 TestFlight internal testing

TestFlight tab → **Internal Testing** → create a group (e.g. `Internal testers`)
→ add testers by Apple ID.

- Internal testers must be **Users** on the App Store Connect team
  (Users and Access → invite the Apple ID you use on the iPhone, and the one on
  the iPad — they can be the **same** Apple ID signed in on both devices, which
  is the simplest setup).
- Internal builds: up to **100 testers**, available **within minutes**, **no App
  Review**, each build usable for 90 days.
- Match the group name to `publishing.app_store_connect.beta_groups` in
  `codemagic.yaml` (or delete that key to just upload without auto-assigning).

**External testing** (only if you later want testers outside the team): up to
10,000 testers via a public link, but the **first** build of each version goes
through a light **Beta App Review** (usually < 24h). Not needed for your
iPhone+iPad loop.

### 4.4 The iPad is just a second TestFlight device

You install the TestFlight app on the iPad, sign in with a tester Apple ID, and
pull the same build. That's the entirety of the iPad's role. **Swift Playgrounds
on iPad cannot build or run a Flutter app** (no Flutter toolchain, no pub, no
plugin pod compilation) — do not go down that path.

---

## 5. Firebase iOS setup (web + Linux)

### 5.1 The iOS app already exists in `ayma-ai`

`lib/firebase_options.dart` already has a fully populated `ios` entry:

```
appId:        1:235381544962:ios:8d9dfb229f63f9c1c4ef1b
iosBundleId:  com.ayma.aymaFlutter
iosClientId:  235381544962-g1omoiumlqilovh53em3jglq5q7jce8t.apps.googleusercontent.com
```

So an **iOS app was already registered** in the Firebase console for this
project. You most likely do **not** need to "Add app" again — just download its
config:

Firebase console → Project `ayma-ai` → Project settings → **Your apps** →
the iOS app (`com.ayma.aymaFlutter`) → **`GoogleService-Info.plist`** →
Download.

If for some reason the iOS app is missing: **Add app → iOS**, bundle id
`com.ayma.aymaFlutter`, App Store ID = the numeric Apple ID from
[§4.1](#41-create-the-app-record), then download.

### 5.2 Where the plist goes

```
ios/Runner/GoogleService-Info.plist
```

Two options for CI:

- **Commit it** (recommended — matches this repo, which already commits
  `android/app/google-services.json`). It is client config, not a secret.
  Then delete the base64 fallback step from `codemagic.yaml`.
- **Or** keep it out of Git and give Codemagic
  `GOOGLE_SERVICE_INFO_PLIST_B64` (`base64 -i ios/Runner/GoogleService-Info.plist`)
  as a **secure** env var in the `appstore_credentials` group — the workflow's
  first script decodes it.

> **Sanity check after download:** open the plist and confirm `REVERSED_CLIENT_ID`
> equals the scheme already written into `ios/Runner/Info.plist`:
> `com.googleusercontent.apps.235381544962-g1omoiumlqilovh53em3jglq5q7jce8t`.
> If Firebase rotated the iOS OAuth client, update **both** `Info.plist` and
> `lib/firebase_options.dart`.

### 5.3 Re-generating `firebase_options.dart` (optional, works on Linux)

The `ios`/`macos` entries in `firebase_options.dart` can be refreshed without a
Mac:

```bash
dart pub global activate flutterfire_cli
cd ayma_flutter
flutterfire configure --project=ayma-ai --platforms=ios,android
```

This rewrites `firebase_options.dart` and drops `GoogleService-Info.plist` in
place. It does **not** need Xcode. If you'd rather not run it, the existing
hand values are already correct — just add the plist file.

### 5.4 APNs key → Firebase

Firebase console → Project settings → **Cloud Messaging** tab → **Apple app
configuration** → **APNs Authentication Key** → Upload:

- the `AuthKey_<APNs KeyID>.p8` from [§2.2](#22-apns-auth-key-for-fcm-push--p8-token-based)
- its **Key ID**
- your **Team ID**

Without this, `FirebaseMessaging.getToken()` returns `null` on iOS and
`PushService.syncToken()` silently no-ops (it's best-effort by design — see
`lib/services/push_service.dart`).

---

## 6. Codemagic setup

<https://codemagic.io> → sign in with GitHub → add the repo.

1. **Team → Integrations → App Store Connect API key** → add:
   - Key name: pick one, e.g. `CODEMAGIC_ASC_API_KEY` → put it in
     `codemagic.yaml` under `integrations.app_store_connect`.
   - Issuer ID, Key ID, and the `AuthKey_<ASC KeyID>.p8` from
     [§4.2](#42-app-store-connect-api-key-for-ci-upload--signing).
2. **App settings → Environment variables** → group **`appstore_credentials`**:
   - `APP_STORE_APP_ID` — numeric Apple ID from [§4.1](#41-create-the-app-record). Plain.
   - `GOOGLE_SERVICE_INFO_PLIST_B64` — only if you did **not** commit the plist.
     Secure.
3. Edit `codemagic.yaml` — resolve every `TODO`:
   - `integrations.app_store_connect:` → your integration name.
   - `environment.flutter:` → keep matching your local Flutter
     (`flutter --version` → currently `3.32.6`).
   - `publishing.app_store_connect.beta_groups:` → your TestFlight group name,
     or remove.
   - `publishing.email.recipients:` → your address, or remove the block.
4. First build: push to `main`, or hit **Start new build** in the UI.
   - The first run is slowest (`--repo-update`, cert + profile creation).
   - Watch the **"Set up code signing"** step — if it fails, the App ID
     capabilities ([§2.1](#21-app-id-identifier)) or the ASC key role
     ([§4.2](#42-app-store-connect-api-key-for-ci-upload--signing)) are usually
     the cause.
5. On success the build shows in **App Store Connect → TestFlight → iOS builds**
   with status "Processing" for a few minutes, then becomes installable.

---

## 7. CI options compared

| Option | Mac needed? | Free allowance (2026) | Flutter DX | Notes |
|---|---|---|---|---|
| **Codemagic** ✅ recommended | No | **500 min/mo** on macOS M2 (personal account only, not Teams); overage ~$0.095/min | First-class — Flutter is the default project type, `flutter build ipa` is a one-liner, automatic signing + TestFlight publish built in | Web UI + `codemagic.yaml`. Everything in this doc targets it. A full build here is ~12–18 min, so 500 min ≈ **25–35 builds/month free**. |
| **GitHub Actions** `macos-latest` + fastlane | No | Private repo Free plan: 2,000 Linux-equiv min/mo, but **macOS = 10× multiplier** → only **~200 real macOS min/mo** (~10–15 builds); then ~$0.08/min | Manual — you write the fastlane lanes, signing (`match` or `app-store-connect` action), `flutter build ipa`, `upload_to_testflight` yourself | Fine if you already live in GH Actions and don't mind the multiplier math. More YAML to own. |
| **Bitrise** | No | 300 credits/mo free; a macOS M-series build burns credits fast | Good — has a Flutter step and an iOS auto-provision step | Comparable to Codemagic; smaller free tier for macOS. |
| **Xcode Cloud** | ⚠️ historically yes for onboarding | **25 compute hrs/mo** included with the $99 membership | Native to Apple, zero signing config, direct TestFlight | Creating the first workflow has historically been done **from Xcode on a Mac**; App Store Connect gained a web setup path but whether a pure-web, no-Mac first-time setup works for a **Flutter** project in 2026 is **unconfirmed** — see [§12](#12-things-to-verify--currently-uncertain). Also needs a `ci_post_clone.sh` to install Flutter. Treat as a "later, maybe" once you have Mac access once. |
| **Rented cloud Mac** (MacinCloud / MacStadium / AWS EC2 Mac / Scaleway Mac mini) | It *is* a Mac, over VNC/SSH | None — MacinCloud from ~$1/hr pay-as-you-go or ~$20–30/mo; AWS EC2 Mac has a 24-hr minimum allocation and is pricey | Full `flutter run`, Simulator, Xcode | The escape hatch when you need to debug something iOS-native, do the one-time Xcode Cloud onboarding, or inspect a crash in Instruments. Not needed for the routine push→TestFlight loop. |

**Why Codemagic for this project:** Flutter is its primary use case, the free
tier realistically covers your iteration, automatic signing means you never
generate a cert, and TestFlight publish is a 3-line `publishing:` block. The
`codemagic.yaml` in this repo is ready bar the console-supplied `TODO`s.

---

## 8. What the CI needs (secrets checklist)

| Value | Where it comes from | Goes into |
|---|---|---|
| App Store Connect API key `.p8` | [§4.2](#42-app-store-connect-api-key-for-ci-upload--signing) — ASC → Users and Access → Integrations | Codemagic → Team → Integrations → App Store Connect |
| ASC API **Issuer ID** (UUID) | Same page, shown once | Same integration |
| ASC API **Key ID** | Filename `AuthKey_<KeyID>.p8` | Same integration |
| **Team ID** (10 chars) | developer.apple.com/account → top right / Membership | Usually auto-derived by Codemagic from the ASC key; keep it noted anyway |
| **Bundle ID** `com.ayma.aymaFlutter` | Fixed, in the repo | `codemagic.yaml` `vars.BUNDLE_ID` (already set) |
| `APP_STORE_APP_ID` (numeric) | [§4.1](#41-create-the-app-record) — App Store Connect → App Information | `appstore_credentials` env group |
| Signing cert + provisioning profile | **Auto-created** by `fetch-signing-files --create` on first build | Nothing to paste |
| `GoogleService-Info.plist` (or its base64) | [§5.1](#51-the-ios-app-already-exists-in-ayma-ai) — Firebase console | Committed at `ios/Runner/GoogleService-Info.plist`, **or** `GOOGLE_SERVICE_INFO_PLIST_B64` secure env var |
| APNs Auth Key `.p8` + Key ID + Team ID | [§2.2](#22-apns-auth-key-for-fcm-push--p8-token-based) | **Firebase** (not Codemagic) — [§5.4](#54-apns-key--firebase) |

Nothing here is an env var on Cloud Run; the backend is untouched.

---

## 9. The dev/test loop with no Mac

There is **no `flutter run` on iOS, no hot reload, no iOS Simulator** without
macOS. Accept that up front. The loop is:

```
edit Dart  →  git push origin main  →  Codemagic build (~12–18 min)
           →  TestFlight processes it (~2–10 min)
           →  TestFlight app on iPhone/iPad shows "Update"  →  install  →  test
```

Practical mitigations:

- **Do 95% of the work on Android.** The Pixel loop already works with hot
  reload; iOS is for catching the genuinely platform-specific things: Apple
  sign-in, APNs push delivery, the mic/camera/photo permission prompts, LiveKit
  audio-session behaviour when the screen locks, safe-area/notch layout, and
  App Review's plist scrutiny.
- **Batch iOS-only fixes** so each CI build tests several at once.
- **Turn on Codemagic build caching** (Flutter pub cache + CocoaPods) to shave
  minutes.
- **Internal TestFlight**, not external — no review, near-instant.
- Keep an eye on the **500-min/month** budget; ~25–35 builds/month free. If you
  blow through it, either pay overage (~$0.095/min) or rent a cloud Mac for a
  focused day.
- For a native crash you can't diagnose from logs, rent a **MacinCloud** hour
  and open the `.xcarchive` / device console.

The iPad adds nothing to the loop except a second screen size to eyeball — the
app is portrait-locked, so mostly it's "does the layout breathe on a 11–13"
portrait canvas".

---

## 10. First upload gotchas (things that bite once)

- **Build number must increase** on every TestFlight upload. `codemagic.yaml`
  auto-bumps via `get-latest-testflight-build-number` + 1. If that command
  fails on the very first build (no builds yet), the fallback `|| echo 0` makes
  it `1`.
- **Export compliance.** First TestFlight build asks about encryption. The app
  uses only standard HTTPS/TLS → in App Store Connect set
  `ITSAppUsesNonExemptEncryption = NO`. You can add
  `<key>ITSAppUsesNonExemptEncryption</key><false/>` to `Info.plist` to stop
  being asked each build. *(Not added by the scaffold — decide and add it
  yourself; verify it's still true if you later add custom crypto.)*
- **Sign In with Apple review requirement.** Apple requires Sign in with Apple to
  be offered if you offer Google sign-in. The app already does
  (`sign_in_screen.dart` `_appleOffered`), so you're compliant — just make sure
  the capability is really enabled ([§2.1](#21-app-id-identifier)) or the build
  won't sign.
- **`aps-environment`.** `Runner.entitlements` ships `development`. The App Store
  export step normally promotes it to `production` for the TestFlight IPA. If
  push works in a debug install but **not** on TestFlight, hard-set it to
  `production` (you have no Mac for debug installs anyway, so this is safe).
- **Privacy "nutrition" labels.** App Store Connect → App Privacy: declare data
  collection (Firebase Auth identifiers, approximate location, photos, audio,
  device push token, plus whatever the backend stores). Required before the
  build can go to **external** testers or the store; internal testing doesn't
  block on it but fill it in early.
- **CocoaPods first run** can be slow / flaky on the runner — `--repo-update` is
  in the workflow; a retry usually clears a transient pod spec fetch failure.
- **`min iOS 15`** excludes the iPhone 6 / original iPad Air / iPad mini 3 and
  older. If the test iPad is a 2014-or-earlier model, check it runs iPadOS 15+.

---

## 11. Time + cost summary

| Item | Cost | Time |
|---|---|---|
| Apple Developer Program | **$99 / year** | 15 min to apply; minutes–2 days to approve |
| Codemagic | **$0** within 500 macOS-min/month (personal account) | 30–60 min first setup |
| Apple portal + App Store Connect config (§2, §4) | $0 | 1–2 h first time |
| Firebase iOS config (§5) | $0 | 20–30 min |
| Resolving `codemagic.yaml` TODOs + first green build | $0 (a few build-min) | 1–3 h of push/fix iterations |
| Per build thereafter | ~$0 (or ~$1.20–1.70 in overage if past 500 min) | ~15–20 min wall-clock |
| Optional cloud Mac for native debugging | ~$1/hr (MacinCloud) | as needed |

**Bottom line:** ~$99 up front, effectively $0/month CI, and half a day to a
first TestFlight install if the Apple approval is quick.

---

## 12. Things to verify / currently uncertain

Flagged rather than guessed — confirm these against current (2026) tooling:

1. **`firebase_messaging` AppDelegate requirement.** As of the 15.x/16.x line the
   plugin swizzles the AppDelegate and needs **no** Swift code for APNs token
   forwarding. Re-check the plugin's iOS setup page for the exact version in
   `pubspec.lock` (`firebase_messaging: 16.6.0`) before assuming
   `AppDelegate.swift` needs nothing. If you disable swizzling you must add
   `didRegisterForRemoteNotificationsWithDeviceToken` →
   `Messaging.messaging().apnsToken = deviceToken`.
2. **Xcode Cloud no-Mac onboarding.** Historically the first workflow was created
   from Xcode. App Store Connect has since added web-based Xcode Cloud setup, but
   whether a brand-new **Flutter** project can be fully onboarded with zero Mac
   access in 2026 is unconfirmed. Don't rely on it as the primary path; Codemagic
   is Mac-free for certain.
3. **Codemagic free minutes and machine types.** Quoted as 500 min/month on
   macOS M2 for personal (non-Team) accounts, overage ~$0.095/min. Verify on
   <https://codemagic.io/pricing/> at signup — free-tier terms move.
4. **GitHub Actions macOS multiplier / included minutes.** Quoted as 10× and
   2,000 included Linux-equiv minutes for private repos on the Free plan
   (≈200 macOS min). Confirm on GitHub's billing docs if you pick this route.
5. **iOS deployment-target floor.** Derived from the installed pod specs today:
   the Firebase pods pin `15.0`. If you bump the `firebase_*` packages, re-run
   `grep -R "deployment_target" ~/.pub-cache/hosted/pub.dev/firebase_core-*/ios`
   and adjust `Podfile` + `project.pbxproj` + `AppFrameworkInfo.plist` together.
6. **`google_sign_in` v7 URL scheme.** v7's iOS plugin still needs the reversed
   client id in `CFBundleURLTypes` (done). If a future `google_sign_in_ios`
   reads the client id only from `GoogleService-Info.plist`, the `Info.plist`
   entry is harmless to keep.
7. **`ITSAppUsesNonExemptEncryption`.** Not added by the scaffold. Add
   `<false/>` only after confirming the app ships no non-exempt crypto.
8. **Signing role.** `fetch-signing-files --create` needs the ASC API key to have
   at least **App Manager**. "Developer" is not enough to create a distribution
   cert.
