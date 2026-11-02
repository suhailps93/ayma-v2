# Meta Model API usage figure — BLOCKED (no authoritative $ source reachable)

Task chunk from Astro (PM): find the AUTHORITATIVE dollar figure for total $
used against the $150 Meta Model API credit on Ayma's Meta hackathon account,
for the Meta hackathon submission draft (which currently carries only
call/token counts).

## Outcome: BLOCKED — no authoritative dollar figure reachable from this box

No authoritative Meta Model API dollar usage figure could be obtained. No
figure is quoted below, and no token-derived estimate was computed (per the
brief, that would not be the deliverable). Everything tried is listed in
order under "What was tried".

As-of: 2026-11-02 ~08:15 PT (UTC-8), the time the last probe below completed.

## What Astro / the founder must provide to unblock

The Meta Model API exposes **no usage, billing, or credits API endpoint**
(corroborated by live probing + independent third-party sources — see tries
4–6). The ONLY authoritative source is the logged-in developer console:

1. Open https://dev.meta.ai/usage and https://dev.meta.ai/billing logged in
   as the hackathon account (Account Team ID `1115399524571844`,
   Project `1115393394567311`).
2. Quote exactly what the pages show: total $ used / billed to date, the
   $150 credit postings (whether the credit has posted at all — as of the
   2026-10-26 docs it had been claimed but NOT yet posted, meaning spend
   until then billed the card on file), remaining credit, and the billing
   period each figure covers.
3. Record the as-of timestamp (with timezone) shown on the page, plus a
   screenshot.

Per `AGENTS.md` default delegation, the browser/console read is Muse's job
(Muse via chrome-devtools); the standing vendor-spend flow is
`docs/AGENT_HANDOFF.md` §"Muse posts figures it reads from vendor billing
pages to `POST /admin/vendor-spend`". Note the gap found in try 8: Meta is
not in `functions/bootstrap/vendor_catalog.json`, so a Muse-posted Meta
figure would be rejected by validation today — adding a `meta` catalog entry
first would let the figure land in the `vendor_spend` collection with
`source_url` + `fetched_at` like every other vendor. Alternatively the
founder can read the two pages directly (fastest path given the Nov 4
9 PM ET submission deadline).

Remaining credit ($150 minus used) cannot be stated: neither the used figure
nor the credit-posting status is visible from here.

## Account / endpoint identifiers found (all non-secret)

- Console: https://dev.meta.ai/ — usage page https://dev.meta.ai/usage,
  billing page https://dev.meta.ai/billing (page paths corroborated by two
  independent third-party sources; login wall confirmed live in try 6).
- API base: `https://api.meta.ai/v1` (matches `config.py`
  `meta_api_base_url` default and `docs/META_PROVIDER.md`).
- Account Team ID `1115399524571844`, Project `1115393394567311`
  (from `docs/META_PROVIDER.md` "Status (2026-10-26)").
- `META_API_KEY` lives in Google Secret Manager (`META_API_KEY`,
  project `ayma-ai`), mounted to Cloud Run in `scripts/deploy-api.sh` /
  `deploy-agent.sh`. Its VALUE is not recorded anywhere in this doc.
- Docs: https://dev.meta.ai/docs/quickstart,
  https://dev.meta.ai/docs/pricing-rate-limits (per-token rates live there;
  deliberately not transcribed here — rates are not usage).

## What was tried, in order (all read-only; no secret value printed anywhere)

1. **Repo + docs search for a recorded figure or console URL**
   (2026-11-02 ~07:55 PT). Searched the worktree for Meta Model API
   references, usage/billing endpoints, console URLs, billing emails and
   receipts. Found only identifiers (above), the $150-claim status
   ("submitted", credit not posted as of 2026-10-26), and the standing
   warning that Meta calls bill the card until the credit posts
   (`docs/META_PROVIDER.md`, `docs/HACKATHON_RULES_UPDATE.md`,
   `docs/HACKATHON_STATUS.md`, `docs/SUBMISSION_WRITEUP.md` §9). No dollar
   usage figure recorded anywhere. No billing-email or receipt mention
   anywhere in the repo. Dead end.

2. **Internal token ledger as a $ source** (2026-11-02 ~08:00 PT).
   `functions/bootstrap/token_ledger.py`: `muse-spark` model ids map to
   provider `meta`, but `_MODEL_PRICING` contains NO Meta entry, so
   `cost_usd_for` returns `0.0` for every Meta call by design ("an unlisted
   or unpriceable model contributes $0 rather than a guess"). The ledger
   cannot supply dollars. Dead end (and deriving $ from its token counts
   is explicitly not the deliverable).

3. **Secret Manager credential check** (2026-11-02 ~08:02 PT).
   `gcloud secrets describe META_API_KEY --project ayma-ai`: secret EXISTS
   (created 2026-10-26). Value never displayed; used only inside shell
   command substitution for the authenticated probes below (never echoed,
   never written to disk). No other Meta credential (console login, billing
   API token) exists in Secret Manager or env.

4. **Authenticated Meta API probes for usage/billing endpoints**
   (2026-11-02 ~08:05 PT, key used via substitution, never printed).
   `GET /v1/models` → **200** (key works; lists `muse-spark-1.3`,
   `muse-wonder-1.0`, `muse-image-1.0`, `muse-voice-transcribe-1.0`,
   `sam-3.1`, contributor variants). `GET /v1/usage`, `/v1/billing/usage`,
   `/v1/organization/usage`, `/v1/dashboard/billing` → **all 404 with empty
   bodies**. Dead end.

5. **`GET /v1/status` + response headers** (2026-11-02 ~08:07 PT).
   `/v1/status` (no auth) → 200 but health-only:
   `{"is_alive":true,"service_status":"operational",...}` — no account or
   usage data. `/v1/models` response headers carry NO `x-ratelimit-*` /
   usage / credit / quota headers. Dead end.

6. **Console pages without login** (2026-11-02 ~08:07 PT).
   `https://dev.meta.ai/usage` fetches only the public marketing landing
   page (login at `/api/auth/login`); no usage data without an
   authenticated session. This box has no browser-automation tooling in
   reach and no Meta-account login credential (founder-owned); a `chrome`
   binary exists but there is no way to drive a founder login from here.
   Dead end from this box — this is the step that needs Muse or the
   founder (see "unblock" above).

7. **Public docs for a usage/billing API** (2026-11-02 ~08:05–08:10 PT).
   `dev.meta.ai` docs nav lists no usage/billing API reference; the
   Dashboard (`/platform`) is the usage surface. Two independent
   third-party sources state the Model API exposes NO usage/billing/
   credits endpoint (only `GET /v1/models` + `GET /v1/status`) and that
   usage/billing live at `dev.meta.ai/usage` + `dev.meta.ai/billing`:
   `github.com/sriinnu/runic` (`docs/muse.md`) and `big-agi.com/docs/connect-meta`. Consistent with tries 4–6. Dead end for API access.

8. **`vendor_spend` Firestore collection (Muse-posted console figures)**
   (2026-11-02 ~08:08 PT). `functions/bootstrap/vendor_spend.py` stores
   console-read figures, but `vendor_catalog.json` has NO `meta` vendor
   (24 vendors: cloud_run … livekit_credits) and `validate()` rejects
   unknown vendor ids — so no Meta figure could have been posted through
   this channel. No prod query needed; provably empty of Meta. Dead end
   (and a gap worth closing — see "unblock" above).

9. **Billing/usage notification emails** (2026-11-02 ~08:08 PT). No Meta
   billing email or receipt is referenced anywhere in the repo or handoffs;
   this box has no Gmail access (no mail tooling). Cannot check. Dead end
   from here; if the founder has a Meta spend-limit/receipt email, its
   quoted figure + date would be a citable (if point-in-time) source.

## Deliberately NOT done

- No token×rate multiplication: the brief forbids estimates, and Meta's
  per-model $ pricing is not in the repo's ledger for exactly that reason.
- No login attempts, no credential creation, no purchases/plan changes.
- No merges; branch-only work. No secret value written to any file.
