# Handoff: Explore Blank Tiles (Issue F1)

## Summary of Investigation & Comparison
Issue F1 reported that on build 1.30.0 (2242), Explore match cards render blank/dark photo tiles while avatar images load fine in Messages.

We compared the two image-loading paths end-to-end:

### 1. URL Source
- **Messages Avatars (`MessagesScreen`)**:
  - Client queries `POST /profiles/mini` via `_ensureMini()` for visible thread UIDs.
  - Backend `main.py` -> `_primary_profile_photo_path()` reads `users/{uid}/profile/main` doc `photos` list.
  - It sorts `photos` by `order` and **loops over each entry (`for e in entries:`)**:
    - If `storage_path` is present on the entry, returns it.
    - If `media_id` is present, it looks up `users/{uid}/user_media/{media_id}`. If it has a valid `storage_path`, returns it.
    - If an entry has a dangling `media_id` or missing `storage_path`, **it falls through to the next photo in the list**.
  - `public_profile._photo_url(path)` mints a token URL from Firebase Storage.
  - Consequently, Messages successfully resolves a valid photo URL even if the user's primary/first photo entry had an unresolvable media ID.

- **Explore Cards (`ExploreScreen`)**:
  - Client queries `GET /explore` via `ApiClient.explore()`.
  - Backend `functions/bootstrap/explore.py` called `_primary_photo_path(db, other, prof.get("photos"))`.
  - In `explore.py`, `_primary_photo_path` previously performed `first = min(entries, key=lambda p: p.get("order", 0))` and checked **only the single first entry**. If `first` had no valid `storage_path` in `user_media`, it returned `None` immediately without checking subsequent photos in `entries`.
  - This left `photo_url: ""` in the `ExploreCard` data, causing Explore cards to fail to obtain a photo URL even when Messages succeeded.

### 2. CachedNetworkImage vs Raw Image.network
- Both Explore (`_Photo` -> `AymaPhoto`) and Messages (`_Row` -> `AymaPhoto`) use `AymaPhoto`, which wraps `CachedNetworkImage` with disk caching and decode-size limiting (`memCacheWidth` / `maxWidthDiskCache` scaled to `displayWidth * dpr`).
- Neither path uses raw `Image.network` (an earlier legacy pattern that previously caused uncached and full-HD downloads).

### 3. Error / Loading Handling
- **Messages**:
  - When `photo.isEmpty`, Messages gracefully renders an avatar placeholder container with `ac.bgCard` and the user's initial: `name.isNotEmpty ? name[0].toUpperCase() : '?'`.
  - Inside `AymaPhoto`, if an image load errors, it falls back to `_fallback(context)` (a subtle `image_not_supported_outlined` icon in a styled container).
- **Explore**:
  - `_Photo` created a fallback with `DecoratedBox(gradient: LinearGradient(...))` using dark HSL values (lightness 0.30 and 0.18) with **no child widget** (no initial, no icon, no text).
  - If `card.photoUrl` was empty or if `AymaPhoto` encountered an error loading the photo, `_Photo` returned this completely blank and dark gradient tile.
  - To users, this rendered as an empty, dark, broken-looking box.

---

## What We Did (Minimal Fix)

1. **Backend URL Fallback Parity (`functions/bootstrap/explore.py`)**:
   - Updated `_primary_photo_path()` to sort `photos` by `order` and iterate through all entries (`for e in entries:`), matching `main.py`'s `_primary_profile_photo_path()`. If the first photo entry has a dangling/unresolvable `media_id`, it now falls back to subsequent photo entries rather than returning `None`.
   - Added unit test `test_primary_photo_path_falls_back_when_first_has_no_storage_path` in `functions/bootstrap/tests/test_explore.py`.

2. **Frontend Graceful Error Placeholder (`ayma_flutter/lib/screens/explore_screen.dart`)**:
   - Updated `_Card` to pass `name: card.name` into `_Photo`.
   - Updated `_Photo`'s fallback: instead of an empty dark box, the fallback tile displays the person's initial (`name[0].toUpperCase()`, consistent with Messages) or an `Icons.person_outline` icon centered over the seeded gradient.
   - Added unit test `card with empty photoUrl renders graceful initial placeholder` in `ayma_flutter/test/explore_screen_test.dart`.

---

## Files Changed
- `functions/bootstrap/explore.py` (updated `_primary_photo_path` loop)
- `functions/bootstrap/tests/test_explore.py` (added fallback test)
- `ayma_flutter/lib/screens/explore_screen.dart` (passed name to `_Photo` and added graceful initial/icon placeholder)
- `ayma_flutter/test/explore_screen_test.dart` (added unit test for initial placeholder)

---

## Tests Run & Results

1. **Backend Tests**:
   - `pytest tests/test_explore.py`: 17 passed in 1.11s.
   - `pytest tests/test_matching_endpoints.py`: 22 passed in 1.14s.
2. **Flutter Analyzer**:
   - `flutter analyze`: "No issues found! (ran in 8.5s)"
3. **Flutter Widget Tests**:
   - `flutter test test/explore_screen_test.dart`: 13 passed in 00:02.
4. **Flutter Layout Matrix Tests**:
   - `flutter test test/layout_matrix_test.dart`: All 21 layout matrix test cases passed.
   - `flutter test test/layout_matrix_shard1_test.dart test/layout_matrix_shard2_test.dart`: All 39 layout matrix shard cases passed. Zero RenderFlex overflows, zero exceptions.

---

## How the Tester Verifies the Fix on the Emulator

1. **Launch the App on Emulator**:
   Ensure `emulator-5554` (or target emulator) is running with the app:
   ```bash
   cd ayma_flutter
   flutter run -d emulator-5554
   ```
2. **Navigate to Explore Tab**:
   - Tap the **Explore** tab on the bottom navigation bar.
3. **Verify Photo Tiles**:
   - Cards with valid photos load with cached images via `AymaPhoto`.
   - Any card where the user has no photo (or an account where photo loading encounters an error) displays a graceful placeholder with the user's initial (e.g. "A" for Alexander) and seeded background, matching the Messages avatar design, rather than an empty/dark blank box.
4. **Compare with Messages**:
   - Tap the **Messages** tab.
   - Confirm avatars show consistent user initials when images are absent or loading.
   - Return to **Explore** and confirm cards maintain full legibility and appearance across scroll, tab switching, and dark/light modes.

---

## What Remains
- None on this branch. The fix is minimal, tested, and ready.
