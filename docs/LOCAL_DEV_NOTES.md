# Local Dev Environment Notes

Machine-specific setup details that aren't part of the product spec (`ARCHITECTURE.md`)
or the build sequence (`PLAN.md`). Recorded during Environment Setup so later sessions
don't re-derive them.

## Firebase / GCP auth (non-interactive)

`firebase-tools` here authenticates with a **service-account key**, not `firebase login`:

- Service account: `firebase-deployer@ayma-ai.iam.gserviceaccount.com`
  Roles: `firebase.admin`, `editor`, `iam.serviceAccountUser`, `serviceusage.serviceUsageAdmin`
- Key file: `.secrets/firebase-deployer.json` (gitignored, `chmod 600`)
- Wired via `GOOGLE_APPLICATION_CREDENTIALS` in `.env.local` (gitignored).
  `python-dotenv` loads it for the backend; for CLI use, `set -a && . ./.env.local && set +a`.
- Project binding: `.firebaserc` → `default: ayma-ai`. `gcloud config` also targets `ayma-ai`.

Deployed environments get these from Google Secret Manager (Phase 13, §12.3) — never this file.

### Why not `firebase login`

Node **22.23.0** (this machine's default via nvm) has an HTTP-stack regression: every
`firebase-tools` token fetch from a Google endpoint fails with
`FetchError: ... Premature close` (`gtoken` / `google-auth-library` / `node-fetch`) —
for both `firebase login` user credentials **and** `GOOGLE_APPLICATION_CREDENTIALS`
service-account keys. `curl`, `gcloud`, and native `node fetch` to the same endpoints
all succeed; only `firebase-tools`' bundled stack fails. Node **20.19.4** (LTS) is fine.

### The Node 20 shim

`firebase-tools` (15.28.2) is installed under Node 20.19.4. `~/.local/bin/firebase`
(first on `PATH`) is a shim that always runs it with the Node 20 binary, regardless of
the active nvm version. `.nvmrc` pins this repo to `20.19.4`. Delete the shim to revert.

## Backend (Cloud Run)

- Service `ayma-api`, project `ayma-ai`, region `us-central1` (matches Firestore).
- URL: `https://ayma-api-235381544962.us-central1.run.app` — `GET /health` → `200`.
- Deployed with `--allow-unauthenticated` for now (Step 1). ID-token middleware
  and a locked-down deploy come later (§10.4). Deploy command in
  `functions/bootstrap/README.md`.
- This URL gets wired into the Flutter client's `lib/env.dart` at the step that
  introduces client bootstrap config (§1.7 step 1).

## Flutter

- `flutter doctor`: Flutter / Android / Chrome / connected-device checks pass.
- **Linux-desktop toolchain deliberately not installed** — app targets Android/iOS only
  (package `com.ayma.ayma_flutter`). Approved deviation, also noted in `PLAN.md`.
- Android emulator available: `Medium_Phone_API_36.0`.

## Not yet configured (deferred per PLAN)

- **LiveKit Cloud** — needed Phase 2. Placeholders in `.env.local` (`LIVEKIT_URL`,
  `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`).
- **Instagram/Meta app** — needed Phase 10.

## Pre-existing state in `ayma-ai`

The reused `ayma-ai` Firebase project already carries config from the prior build:
apps `ayma-android`, `ayma (android)`, `ayma (ios)`, `ayma (web)`, and service accounts
`firebase-adminsdk-fbsvc`, `firebase-app-distribution-admin`, `vertex-express`.
Step 1 decides which app registration the rewrite's Flutter app uses.
