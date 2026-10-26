# Feature flags

Every runtime flag lives in ONE Firestore doc, `config/feature_flags`, read by
`functions/bootstrap/feature_flags.py` (typed, cached 60 s). This is the
`all-features-on` branch: every flag below defaults ON, i.e. the code defaults in
`config.py` are flipped. At last check (2026-10-25) the live `config/feature_flags` doc did not exist, so
the code defaults apply (plus any legacy `config/llm_routing` values). The architecture diagram and the
Inference-vs-Vertex routing table are in `docs/ARCHITECTURE.md` section 0.

## Resolution order (highest first)

1. `FLAG_<NAME>` environment variable (local dev, tests, emergency pin), e.g. `FLAG_MAPS_GROUNDING=false`.
2. `config/feature_flags` -> `<name>`.
3. Legacy docs, still honoured: `config/llm_routing` (`json|vision|chat|voice` groups, `fallback`) and `app_config/sentry` (`enabled`).
4. Code default in `config.py` (fed by the old per-flag env vars such as `LLM_ROUTE_JSON`).

A wrong-typed value is logged and ignored (next layer applies). An unreadable Firestore keeps the last good doc.

## Flags

| Flag | Type | Default (this branch) | Controls |
|---|---|---|---|
| `llm_route_json` | `inference`/`vertex` | `inference` | text JSON jobs (matching, wiki, icebreakers, ...) |
| `llm_route_vision` | `inference`/`vertex` | `inference` | JSON jobs with images / wav / mp3 |
| `llm_route_chat` | `inference`/`vertex` | `inference` | text chat turn incl. function calling |
| `voice_provider` | `inference`/`google` | `inference` | voice agent backend (LiveKit Inference realtime vs Google Live) |
| `llm_percent_json` / `_vision` / `_chat` / `_voice` | 0-100 | 100 | share of calls sent to Inference when the route is `inference` |
| `llm_allowlist_json` / `_vision` / `_chat` / `_voice` | uid list | empty | non-empty = only these uids use Inference |
| `llm_fallback_to_google` | bool | **false** | on an Inference failure retry on Google. Off = the error is logged at ERROR and raised, no silent fallback. Other branches keep it on. |
| `maps_grounding` | bool | true | Google Maps grounding in text chat |
| `deepdive_public_profiles` | bool | true | deep-dive public social-profile photo discovery |
| `deepdive_blocked_regions` | string list | `illinois, texas, eu` | region keys (`illinois`, `texas`, `washington`, `eu`; mapped to cities/states/countries/codes in `region_data.json`) for which that step is skipped |
| `vertex_ai_search` | bool | true | Vertex AI Search website source for deep-dive discovery |
| `vertex_ai_search_daily_cap` | int | 300 | hard max queries per UTC day (0 disables) |
| `meta_integrations` | bool | **false** | Instagram / Facebook connect, sign-in and photo import. Deferred to V2: off hides every app entry point and makes `/instagram/*` return 404 "not available". Mirrored to `app_config/meta_integrations.enabled` for the client. |
| `sentry` | bool | true | Sentry error reporting; the DSN still comes from Secret Manager (no DSN = off) |
| `dev_panel` | bool | true | the app's hidden Developer panel (7 taps on the build stamp in User settings) and dev-facing AI annotations. Turn OFF at store release. Mirrored to `app_config/dev_panel.enabled`, which the app listens to live. Also switchable from the panel itself with `DEV_PANEL_PASSWORD` (`POST /dev/flags`, see below). |

The grouped rows expand to `llm_percent_json`, `llm_percent_vision`, `llm_percent_chat`, `llm_percent_voice`, `llm_allowlist_json`, `llm_allowlist_vision`, `llm_allowlist_chat`, `llm_allowlist_voice`.

Legacy per-flag env vars (`LLM_ROUTE_*`, `VOICE_PROVIDER`, `LLM_INFERENCE_FALLBACK`, `GEMINI_MAPS_GROUNDING`, `DEEPDIVE_PUBLIC_PROFILES`, `DEEPDIVE_PUBLIC_PROFILES_BLOCKED_REGIONS`, `VERTEX_AI_SEARCH`, `VERTEX_AI_SEARCH_DAILY_CAP`, `SENTRY_ENABLED`) still set the level-4 default.

Voice "provider=inference, percent 100, no allowlist" is `voice_provider=inference`, `llm_percent_voice=100`, `llm_allowlist_voice=[]`.

## Flip, inspect, roll back

```
python3 scripts/flags.py list                              # effective value + source of every flag
python3 scripts/flags.py set maps_grounding=false --yes    # without --yes it is a dry run
python3 scripts/flags.py set llm_fallback_to_google=true llm_route_chat=vertex --yes
python3 scripts/flags.py rollback --yes                    # one line: restore the values from before the last write
python3 scripts/flags.py history
python3 scripts/flags.py load scripts/feature_flags.seed.json --yes   # first-time seed
```

Each write stores the previous flag values in the doc's `_history` (last 20), which `rollback` pops. `sentry`, `meta_integrations` and `dev_panel` are also mirrored to `app_config/<flag>.enabled`, because the mobile client reads those docs (it cannot read `config/feature_flags`). For `sentry` and `dev_panel` the app treats a missing doc as ON and only a literal `false` as off; `meta_integrations` is OFF unless the doc says a literal `true` (the app caches the last value for the next launch). Changes take effect within ~60 s, no deploy. The admin dashboard (`/admin`, "Feature flags") shows the effective values read-only (`GET /admin/feature-flags`).

## Requirements that come with these defaults

* Voice on Inference needs `livekit-agents` >= 1.8: `requirements-agent.txt` (the only agent image) pins 1.8.9 and `openai>=3.19,<4`. On the Google path 1.8.9 would default 3.8-live tools to NON_BLOCKING, so `agent.py` pins `tool_behavior=BLOCKING` (Developer API path only; Vertex rejects the field).
* Chat on Inference cannot ground on Google Search / Maps (the gateway has none): `web_search` runs as a function tool answered by a grounded Vertex call (unchanged). Maps grounding therefore only applies to chat turns that run on Vertex (Vertex route, or fallback).
* Models: only the locked ids are used (`config.py`): `google/gemini-3.7-flash` for JSON/vision/chat, `google/gemini-3.8-live` for voice. No new model id was introduced.

## Vertex AI Search (public websites)

* Resources (project `ayma-ai`, location `global`): data store `ayma-public-web` (`PUBLIC_WEBSITE`, 50 URI patterns from `scripts/vertex_search_domains.txt`) and Enterprise-tier engine `ayma-public-web-engine` (website search is not served by a bare data store). Recreate/sync with `python3 scripts/vertex_search_setup.py` (idempotent, uses your gcloud identity).
* Use: `vertex_search.py` queries the engine with the runtime identity (needs `roles/discoveryengine.viewer` or editor on the service account), parses profile URLs plus the already indexed `og:image`, and `deep_dive_public_profiles.py` merges them with the grounded Gemini results. No login, nothing third-party is fetched for indexed images, face verification is unchanged.
* Limits (basic website search): no domain verification is needed and none is possible for third-party domains. The store can only return pages Google has already crawled for those patterns; it cannot force a crawl, re-crawl or index login-walled content, and freshness is Google's. Advanced website indexing (on-demand recrawl, autocomplete, structured data) requires proving ownership of the domain and is not available for domains Ayma does not own.
* Cost: Enterprise-tier search is billed per query (list price about USD 4 per 1,000 queries; check the pricing page); the data store itself has no per-document charge for website search. The `vertex_ai_search_daily_cap` counter (`vertex_search_usage/{UTC date}` in Firestore) caps spend at 300 queries (about USD 1.20) per day by default. At the cap the source returns nothing and deep dives continue on the grounded source.

## Switching `dev_panel` from the app

`POST /dev/flags` `{"password": "...", "dev_panel": true|false}` (signed-in caller) lets the Developer panel switch `dev_panel` live. Only `dev_panel` is accepted (any other key is a 422). The password is checked server-side in constant time against the `DEV_PANEL_PASSWORD` secret (Secret Manager, mounted on `ayma-api` by `scripts/deploy-api.sh --full`); it never ships in the app and is never logged. Unset secret = every toggle refused (503). Lockout: 5 wrong passwords lock that account for 15 minutes and 10 from one client address lock that address for 15 minutes (counters in `dev_panel_attempts/{uid|ip_<hash>}`; the address is hashed); a generous global ceiling of 200 wrong passwords per 15-minute window (`_all`) stops a distributed run, and no few clients can reach it, so nobody is locked out by other people's guesses, plus a 10/minute rate limit. The write goes through the same history/rollback path as `scripts/flags.py`. When `dev_panel` is off, 7 taps still open the panel but it shows only this switch, so it can be turned back on. `GET /dev/flags` returns the effective value.
