# Deep dive: public-profile photo discovery

Code: `functions/bootstrap/deep_dive_public_profiles.py`, wired into
`deep_dive_images.find_web_images`. Prompt: `prompts/deep_dive_public_profiles.md`.

## Flags (read at call time; rollback = config flip, no deploy)

- `DEEPDIVE_PUBLIC_PROFILES` — `1`/`true`/`yes`/`on` enables. **Default ON on all-features-on.**
- `deepdive_blocked_regions` (flag; env `FLAG_DEEPDIVE_BLOCKED_REGIONS`) —
  comma-separated region keys, default `illinois,texas,eu`. The target's
  profile `location` is normalised (case, accents, punctuation) and matched on
  whole words against the maintained mapping in
  `functions/bootstrap/region_data.json` (state/country names, major cities,
  alternate spellings, and two-letter codes only as the trailing part of a
  multi-part location such as "Chicago, IL"). Keys: `illinois`, `texas`,
  `washington` (excludes Washington DC), `eu` (27 member states). A token that
  is not a key is matched as a plain phrase. A match skips the source
  entirely. An empty or unrecognised location is allowed (biometric consent is
  already required) and logged without the location text. Code:
  `region_block.py`.

## How it works

1. One Gemini call grounded with Google Search + URL context lists public
   profile URLs (allowlisted platforms + personal sites; max 8, one per platform).
2. Each URL: robots.txt check (honest UA `AymaDeepDive/1.0`), one plain GET, no
   cookies/login, redirects into login/auth paths and 401/403/429/999 are
   skipped. The `og:image`/`twitter:image` is the candidate. Every fetch (robots.txt,
   page, image) goes through `public_url.py`: http(s) only, the host must resolve to
   public addresses only, and each redirect hop is re-checked (SSRF guard), so a
   model- or page-supplied URL can never reach an internal address.
3. Candidates go through the unchanged gate (cosine >= 0.55 plus
   `_has_detectable_face`). Image bytes live only in memory during verification;
   only the verified URL + similarity (+ `platform`) are kept. The platform of
   each verified image is logged. Results are cached in-process for 24h.

Own consented photos / reference embeddings are untouched.

## Vertex AI Search website datastore (added: see vertex_search.py)

Not added: indexing third-party domains (instagram.com, linkedin.com, ...)
requires domain ownership verification for advanced website search, and those
sites block crawlers via robots.txt/login, so the datastore would stay empty
for the platforms that matter. Pricing is usage-based (per-query plus indexed
storage; no fixed monthly fee as far as documented), but creation of a
website datastore with advanced indexing involves a console-side domain
verification step. Re-verify against current Google pricing before revisiting.

## Legal / privacy

Comparing the face of a person who has not consented to their photo found on
the open web is biometric processing. Exposure includes Illinois BIPA (private
right of action, statutory damages), Texas CUBI (AG enforcement), Washington
biometric law, GDPR art. 9 (special-category data, explicit consent or another
art. 9 basis required; also art. 14 notice), UK GDPR, and platform terms of
service (public availability does not grant a license to scrape or match).
Keep the flag OFF until counsel has reviewed: lawful basis per region, notice,
retention (we keep only URL + similarity), and the blocked-region list.

## Biometric consent (2026-10-25)

Every Ayma account now gives a mandatory, separate face-matching consent
(`functions/bootstrap/biometric_consent.py`, record on
`users/{uid}.biometric_consent`; app: a required checkbox on the sign-in page,
separate from the Terms/Privacy checkbox, recorded right after the first
sign-in, or the one-time `/consent` screen for older accounts). The server
refuses every authenticated feature endpoint without it (403
`biometric_consent_required`), and every face-embedding / face-match path
(`find_web_images`, `reference_embeddings_for`, `deep_dive_social`,
`photo_pipeline`, `photo_notes`, reverse-image `auto_scan`, the verification
selfie) checks it again for the person whose face is involved. A deep dive's
target is therefore always an Ayma member who consented (themself, or an
Explore member); no target / no consent means no web-photo matching at all.
Withdrawal (Settings > Face matching consent) deletes the face data and then
the account. The region-block config above is unchanged and still applies on
top of the consent.

The consent screen and the "Biometric information (face matching)" sections of
the Terms and Privacy Policy must be reviewed by an attorney before store
release (BIPA/CUBI/Washington/GDPR art. 9 wording, retention schedule,
withdrawal mechanics). Nothing is disabled pending that review.
