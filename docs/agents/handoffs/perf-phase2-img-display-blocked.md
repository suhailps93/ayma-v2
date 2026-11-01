# Perf Phase 2 step 1 (image-variant DISPLAY wiring) — BLOCKED: backend must expose variant URLs first

From Muse (Engineer), 2026-11-01. Branch: `muse/phase2-img-display` (pushed, NOT merged — no code changes, this note only).

## Verdict

No client code written, deliberately: the tasked surfaces (Explore grid, profile detail) are
cross-user surfaces whose photos arrive as server-minted token URLs, and there is **no
client-only mechanism** to obtain the matching variant URLs. Wiring the client now would mean
wiring to a fiction (constructed variant URLs that 403). Per the task brief ("if [the doc]
proves [a backend change] is required — report it, do not silently expand scope"), this chunk
is BLOCKED on a small backend prerequisite described below.

## Verify-before-fix: generation/serving path is REAL (passed)

- Cloud wiring live: GCS `OBJECT_FINALIZE` (prefix `uploads/`) → Pub/Sub topic
  `storage-image-finalized` → push subscription → `POST /internal/storage/image-finalized`
  (all ACTIVE, verified via gcloud).
- Live rev `ayma-api-staging-00023-czq` serves the route (unauthenticated probe → 403,
  not 404) with `IMAGE_VARIANTS_ENABLED=true`.
- Live E2E 2026-11-01 ~13:46 PST: uploaded 1024x1024 PNG as
  `uploads/verify-live-<ts>/profile_e2e_<ts>.png` → `__thumb_400.png` (400x400, PNG)
  appeared in <45s and downloaded fine; `__medium_1080` correctly skipped (no-upscale
  rule). Test objects deleted after; bucket left with only the 9 `seed_*.png` fixtures.

## The exact gap (three client-only mechanisms ruled out)

In-scope surfaces and their photo sourcing (all verified in tree at `f396a4b`):

1. **Explore grid** — `ayma_flutter/lib/screens/explore_screen.dart` `_Photo` renders
   `ExploreCard.photoUrl`, a server-minted token URL for ANOTHER user's photo
   (`functions/bootstrap/explore.py` → `public_profile._photo_url`).
2. **Profile detail** — `ayma_flutter/lib/screens/public_profile_screen.dart`
   ("Another user's profile — opened from an Explore card") renders `photos[i]`,
   server-minted token URL strings (`public_profile._photos` → `_photo_url`).

Why the client cannot derive variant URLs itself:

- (a) **`getDownloadURL()` on a derived variant ref fails for others' photos.**
  `storage.rules`: `uploads/{uid}/*` readable only by the owning uid. The codebase
  states this twice: `explore.py` ("the client can't resolve another person's photo
  itself") and the `ExploreCard.photoUrl` doc comment.
- (b) **URL string rewriting fails: tokens are per-object.** Proven empirically
  2026-11-01 ~13:48 PST on staging fixtures: control (object path + its own token)
  → HTTP 200; rewritten (sibling object path + first object's token) → HTTP 403.
  A variant object carries a different (or no) `firebaseStorageDownloadTokens`, so
  the original's token cannot authorize it. Fixture metadata restored after.
- (c) **No generic backend resolve endpoint exists to reuse** (only `_photo_url`
  used internally by explore/public-profile/chat-history/photo-notes paths).

Backend responses today carry originals only: `photo_url` (+ back-compat `photo_path`)
on explore cards, `photos[]` URL strings on public profiles. No variant fields.

Out-of-scope note: own-photo surfaces (`photo_service.loadGrid`) COULD resolve variants
client-side (owner read access), but that is the photo-management surface, not the tasked
Explore/profile-detail surfaces, and wiring it alone would not serve the phase goal.

## Backend prerequisite (proposed, staging-gated, small)

In `functions/bootstrap/public_profile.py` + `explore.py` (staging only):

- For each profile-photo storage path, compute variant paths with the existing
  `image_variants.variant_name()` (`__thumb_400` / `__medium_1080`, same ext rules),
  `blob.exists()`-check each, and mint token URLs via the existing `_photo_url()`.
- Explore card: add `photo_url_thumb` (thumb URL, else original URL); public profile:
  add parallel `photos_thumb[]` (and `photos_medium[]` if detail wants it) with
  per-entry fallback to the original URL when the variant is missing — same fallback
  contract as `docs/perf/image-variants.md`, enforced server-side so old clients ignore
  the new fields safely.
- Keep it inert unless variants exist: responses for photos without variants are
  byte-identical in behavior (original URL in both fields).

## What step 1 becomes once the prerequisite lands

Pure client mapping, no SDK tricks: Explore `_Photo` prefers `photoUrlThumb ?? photoUrl`;
profile carousel/detail prefers `medium ?? original`; `AymaPhoto` unchanged (it already
caps decode/cache by `displayWidth`). Fallback = use the original field when the variant
field is empty. Gates per brief: `flutter analyze` clean + full `flutter test` green.

## Worktree/branch state

Worktree `~/workspace/ayma/.fleet-worktrees/phase2-img-display`, branch
`muse/phase2-img-display` off `origin/staging` @ `f396a4b`. Single docs-only commit
(this file), pushed for review. No client/backend code touched; no prod defaults touched.

## UNBLOCKED — backend prerequisite DELIVERED (2026-11-01)

Branch `feat/meta-label-and-variant-urls` (off `origin/staging`, pushed for lead
review — NOT merged) implements the server-side mint described above:

- `image_variants.variant_object_name(object_name, spec, width)` — serve-time
  variant path (no download/GCS call); ext derived from the source path the same
  way `_output_format` maps a decoded image (`.png`→.png, `.webp`→.webp, else→.jpg).
  A wrong-ext guess simply misses `exists()` and the caller falls back to the original.
- `public_profile._variant_url(storage_path, spec, width)` — returns `None` when
  `CONFIG.image_variants_enabled` is false (prod — no GCS call), else mints a token URL
  for the variant object via the existing `_photo_url()` (its own `exists()` + token mint).
- Explore card gains `photo_url_thumb` (thumb-400 URL, else the original `photo_url`).
  `photo_url` / `photo_path` unchanged.
- Public profile gains `photos_thumb[]` and `photos_medium[]`, aligned 1:1 with
  `photos[]`, each entry = its variant URL or the original URL as fallback. The deleted-user
  placeholder carries empty `photos_thumb`/`photos_medium` for shape consistency.

Inert contract preserved: flag off ⇒ the new fields equal the originals with zero extra
GCS calls; flag on but a variant missing ⇒ that entry falls back to its original. Old
clients ignore the new fields.

**Step 1 is now pure client field-mapping:** Explore `_Photo` prefers
`photoUrlThumb ?? photoUrl`; profile carousel/detail prefers `medium ?? original`
(`photosMedium[i]` falling back to `photos[i]`, and `photosThumb[i]` for the smaller
surfaces). No SDK tricks. Muse can resume.
