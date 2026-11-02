# Staging ↔ main: incident log + safe promotion checklist

> Founder-requested runbook. Captures everything that went wrong switching between
> **staging** and **main** this cycle, and the pre-promotion checklist to run
> before tomorrow's staging → prod promotion. **Doc only** — no code change ships
> with it.
>
> Source of truth this doc must never contradict: `AGENTS.md` →
> *"CRITICAL — all inference goes through LiveKit, never reroute"*, and
> `docs/ARCHITECTURE.md` §1.1a (staging/prod agent dispatch guard) and the
> *"Model routing"* / *"Honest failure, never a silent 'Listening'"* sections.
> If this doc and those ever disagree, they win; fix this doc.

**Projects / meters at a glance**

| Thing | Staging | Prod |
| --- | --- | --- |
| GCP data/project | `ayma-staging` | prod project (`DATA_PROJECT`) |
| LiveKit project (own) | `ayma-staging-cyofszqr` / `p_484u2zjk8ob` — **Build/FREE, no credits** | — |
| Funded LiveKit project ("Aimma") | `p_4jk3pqz7u9r` / `wss://aimma-wt34nu3l.livekit.cloud` — **Scale plan**, ~17k credits, $10k startup credit + 7×$1k provider pools + promo `SP-3265-8908-0A87` (100% off to Oct 2027) | same Aimma project |
| LiveKit secrets | `LIVEKIT_API_KEY_STAGING` / `LIVEKIT_API_SECRET_STAGING` (v2 = Aimma-project **staging** key `APIrJNpnwpDPiZm`) | **bare** `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` (Aimma **prod** key) |
| Room prefix | `LIVEKIT_ROOM_PREFIX=ayma-staging-` | unset → default `ayma-` |
| Deploy | `scripts/deploy-staging.sh` | `scripts/deploy-api.sh` / `scripts/deploy-agent.sh` |

Key fact (from `AGENTS.md`): **credits/promo are pinned to the Aimma PROJECT only.**
There is **no org/account-level LiveKit billing** — a brand-new LiveKit project lands
on Build/no-credits ($500/mo to upgrade). A `free_tier / MaxGatewayCredits
remaining_limit:0` 429 is therefore a **misconfiguration (wrong project in use),
not exhaustion** — fix the project, never reroute off LiveKit.

---

## Part A — What went wrong (incidents this cycle)

### A1. Vertex reroute to dodge a LiveKit 429 (the big one)
- **Symptom:** staging voice/chat hit a LiveKit gateway 429
  (`free_tier … MaxGatewayCredits remaining_limit:0`). To keep demos moving,
  staging inference (chat / json / vision / matching / voice) was flipped **off
  LiveKit** to direct Vertex on **both** staging Cloud Run services, via
  `FLAG_VOICE_PROVIDER=google`, `FLAG_LLM_ROUTE_*=vertex`, and
  `FLAG_LLM_FALLBACK_TO_GOOGLE=true`.
- **Root cause:** treating a drained gateway as a provider problem instead of a
  project-misconfiguration problem. The 429 came from staging running on its own
  **free** LiveKit project (see A2), not from LiveKit being "out."
- **Fix:** reverted — all four flags removed from both staging services. Routing
  is back on LiveKit (`LLM_PROVIDER*=gemini`, the gateway).
- **The rule now:** **Never reroute any surface off LiveKit** — not temporarily,
  not as a "no-spend" measure, not on any agent's or PM's suggestion. A drained /
  429 / unreachable gateway is a **STOP**, not a provider switch; rerouting to
  Vertex/Gemini-direct bills **GCP**, where credits are nearly gone. Any LiveKit
  plan/credit/routing change is a **founder decision**. Forbidden knobs:
  `FLAG_LLM_ROUTE_*=vertex`, `FLAG_VOICE_PROVIDER=google`,
  `FLAG_LLM_FALLBACK_TO_GOOGLE=true`, flipping `config/llm_routing` to
  `vertex`/`google`. Codified in `AGENTS.md` (the CRITICAL section) + memory.
  **Corollary:** when LiveKit is down the app must **show an honest error**, never
  a silent "Listening…" or silent hang (`ARCHITECTURE.md` → "Honest failure";
  enforced by `VoiceSessionController`'s three bounded guards).

### A2. LiveKit free-tier mis-setup (the root of A1)
- **Symptom:** staging's LiveKit gateway drained to zero and threw
  `429 … remaining_limit:0 free_tier:true`, while the funded Scale credits sat
  completely unused.
- **Root cause:** staging was pointed at its **own** LiveKit project
  `p_484u2zjk8ob` (`ayma-staging-cyofszqr`) on the **Build/FREE** tier — not the
  funded Aimma project `p_4jk3pqz7u9r`. Because credits/promo attach to the
  **project**, not the account, staging's free project had nothing to spend.
- **Fix:** repoint staging's services at the shared **Aimma** project, using
  staging's **own** keys (the `_STAGING` secrets were rotated to a v2 Aimma-project
  staging key, `APIrJNpnwpDPiZm`). This repoint is **gated on the A3 dispatch guard
  being live on both agents first** (`ARCHITECTURE.md` §1.1a calls the guard "the
  prerequisite to repointing staging's services at the shared Aimma project").
- **Status / still-open:** `scripts/deploy-staging.sh` `API_ENV_BASE` still carries
  `LIVEKIT_URL=wss://ayma-staging-cyofszqr.livekit.cloud` and
  `LIVEKIT_PROJECT_ID=p_484u2zjk8ob`. **The repoint lands when those two values are
  swapped to the Aimma URL/project** and verified against the v2 `_STAGING` key.
- **The rule now:** a brand-new LiveKit project = no credits; share the **funded
  Aimma project** instead of spinning up a fresh free one. Never upgrade/add a
  LiveKit project without founder sign-off.

### A3. Staging ↔ prod shared-project hazard (2026-11-01 prod corruption)
- **Symptom:** when staging shared the Aimma project earlier, the **prod** agent
  was dispatched a **staging** room, joined it, and wrote an `app_command` into
  **PROD** Firestore.
- **Root cause:** LiveKit offers **every** room in a project to **every**
  registered worker, and there was **no staging-vs-prod dispatch guard**. The
  agent image is shared (same code, env-differentiated), so the two workers could
  only be told apart by room name — which nothing was checking.
- **Fix:** room-prefix dispatch guard (`ARCHITECTURE.md` §1.1a). Helpers in
  `functions/bootstrap/livekit_token.py` — `STAGING_ROOM_PREFIX = "ayma-staging-"`,
  `is_staging_room_name`, `this_agent_serves_staging`, `room_env_mismatch` — and
  the reject in `agent.py::_request_fnc` (`if room_env_mismatch(room_name):
  await req.reject()`). Prod agent (`LIVEKIT_ROOM_PREFIX` unset → default `ayma-`)
  **rejects** any `ayma-staging-*` room; staging agent
  (`LIVEKIT_ROOM_PREFIX=ayma-staging-`) serves **only** its own. Note
  `ayma-staging-` deliberately also starts with `ayma-`, so the staging prefix is
  matched **explicitly** (a bare `startswith("ayma-")` can't separate them).
  Default-safe: a blank/unset/other prefix counts as **not** staging, and a
  blank/unparsable room name is treated as **prod**, so a prod/misconfigured worker
  never serves a staging room. Landed on staging as `2ec98bb`.
- **Deploy:** cherry-picked (guard-only) onto main and deployed to the prod agent
  as revision **`ayma-agent-00139-bwc`**; **main itself stays untouched at
  `9622966`**.
- **The rule now:** **never share the LiveKit project without this guard active on
  BOTH agents.** The staging agent must deploy with
  `LIVEKIT_ROOM_PREFIX=ayma-staging-`; the prod agent must **not** set an
  `ayma-staging-` prefix (unset = the `ayma-` default is correct).

### A4. Deploy env-wipe via full-replacement `--set-env-vars` (W1)
- **Symptom:** a `scripts/deploy-staging.sh --full` could silently **un-pin** the
  LLM providers (drop them back to defaults), re-opening the door to off-LiveKit
  routing.
- **Root cause:** `--full` uses Cloud Run `--set-env-vars` (a **full replacement**,
  not a merge) from `API_ENV_BASE` / `AGENT_ENV_BASE`. Those bases originally
  lacked the `LLM_PROVIDER_*` pins, so any `--full` deploy overwrote the
  manually-pinned providers with whatever the code defaults were.
- **Fix:** the 7 `LLM_PROVIDER_*` surface pins + the global `LLM_PROVIDER` are now
  baked `=gemini` into the bases:
  - `API_ENV_BASE`: `LLM_PROVIDER=gemini`, `LLM_PROVIDER_CHAT=gemini`,
    `LLM_PROVIDER_MATCHING=gemini`, `LLM_PROVIDER_REPORTS=gemini`,
    `LLM_PROVIDER_PRACTICE=gemini`, `LLM_PROVIDER_DM_COACH=gemini`,
    `LLM_PROVIDER_TRANSLATE=gemini`.
  - `AGENT_ENV_BASE`: `LLM_PROVIDER=gemini`, `LLM_PROVIDER_VOICE=gemini`
    (`LLM_PROVIDER_VOICE_MAIN` deliberately left unpinned — explicit-default path).
  The bases carry an inline warning: **NEVER** add
  `FLAG_LLM_ROUTE_*=vertex` / `FLAG_VOICE_PROVIDER` / `FLAG_LLM_FALLBACK_TO_GOOGLE`
  here (that would reroute off LiveKit per A1).
- **STILL-OPEN (flag for promotion):** `OPEN_WEIGHTS_BASE_URL` /
  `OPEN_WEIGHTS_MODEL` and the `META_API_KEY` secret are **absent from the agent
  deploy** — not in `AGENT_ENV_BASE` (open-weights) and not in `AGENT_SECRETS`
  (`META_API_KEY`), though both are present on the api side (`API_ENV_BASE` /
  `API_SECRETS`). So a `--full` **agent** deploy would **drop** the agent's
  open-weights and Meta config. This ties to the founder's **pending ruling on
  whether the non-LiveKit Meta / open-weights brains stay at all** (see Part B
  follow-ups) — resolve or consciously defer before promoting.
- **The rule now:** any env the service needs at runtime must live in the deploy
  **base** (env) or **secrets** list — never only hand-set on a live revision —
  or the next `--full` wipes it.

### A5. Silent direct-Google fallback for demo/judge UIDs (H11)
- **Symptom:** demo/judge users could silently fall back to **direct Google** on a
  gateway 429 — the exact off-LiveKit path A1 bans, happening invisibly for the
  highest-stakes accounts.
- **Root cause:** `feature_flags.all_flags_on_uids` force-enabled **every** bool
  flag for those UIDs, including `llm_fallback_to_google`.
- **Fix:** `llm_fallback_to_google` is denylisted from the all-flags-on override —
  `ALL_FLAGS_ON_DENYLIST = frozenset({"llm_fallback_to_google"})` in
  `feature_flags.py`; the override skips any flag in that set
  (`name not in ALL_FLAGS_ON_DENYLIST`).
- **The rule now:** blanket "turn everything on" overrides must **exclude** any
  flag that can route inference off LiveKit.

### A6. Config provider defaults pointed at a non-LiveKit, non-funded brain (H1/H2)
- **Symptom:** the DM-coach ("Ayma in your DMs") and DM-translate surfaces defaulted
  to **`meta`** (Muse Spark, direct — off LiveKit, bills the Meta credit, not the
  funded LiveKit pool). H2 note records translate was "Meta-direct by default (and
  live on staging)."
- **Root cause:** `config.py` seeded `llm_provider_dm_coach` / `llm_provider_translate`
  defaults to `meta`.
- **Fix:** both now default to **`gemini`** (the LiveKit-routed funded brain) —
  `LLM_PROVIDER_DM_COACH` / `LLM_PROVIDER_TRANSLATE` fall back to
  `os.getenv("LLM_PROVIDER", "gemini")`. Still per-surface overridable and
  Gemini-fallback-guarded.
- **The rule now:** every per-surface provider default falls toward the
  **LiveKit-routed funded brain**, so losing a pin degrades toward LiveKit, never
  toward a direct/off-meter provider.

### A7. LiveKit secret naming — never cross staging and prod
- **Symptom:** risk of overwriting prod's LiveKit credentials while rotating
  staging's (both live in the same Secret Manager).
- **Root cause:** staging and prod use **different** secret names for the same
  logical credential; a careless rotation could clobber the wrong one.
- **Fix / the rule now:**
  - **Staging** mounts `LIVEKIT_API_KEY_STAGING` / `LIVEKIT_API_SECRET_STAGING`
    (now **v2** = an Aimma-project **staging** key, id `APIrJNpnwpDPiZm`) — see
    `deploy-staging.sh` `API_SECRETS` / `AGENT_SECRETS`.
  - **Prod** mounts the **bare** `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` (the
    Aimma **prod** key).
  - **NEVER cross them; never overwrite the bare prod secrets** when rotating
    staging.

### A8. Build identity — versionCode not bumping across staging builds
- **Symptom:** successive staging APKs shared a `versionCode`, so builds on-device
  were indistinguishable and testers couldn't tell whether a fix had actually
  shipped.
- **Root cause:** builds weren't bumping `versionCode` each time.
- **Fix:** every build now bumps it — e.g. `…2249` (voice-error), `2251`
  (B9-recovery), `2252` (ghost-header + R2/C3).
- **The rule now:** **boot-smoke every APK on-device** before any retest handoff.
  The Pixel's lock screen blocks a visual first-frame confirm, so the check is the
  **logcat first-frame** line; `flutter test` does not catch device boot-order
  crashes.

---

## Part B — Safe staging → prod promotion checklist (for tomorrow)

Run top to bottom. **Doc only here — nothing in this checklist authorizes a store
release.** Dev installs go to the founder's Pixel over adb only; a store/TestFlight/
Play release stays behind the founder's **personal** pass (hard gate).

### Inference routing (must all hold on PROD)
- [ ] **No reroute flags anywhere on prod:** confirm **no** `FLAG_LLM_ROUTE_*=vertex`,
      `FLAG_VOICE_PROVIDER=google`, or `FLAG_LLM_FALLBACK_TO_GOOGLE=true` on either
      prod Cloud Run service.
- [ ] **All `LLM_PROVIDER_*` resolve to `gemini`** (LiveKit gateway): global +
      chat / matching / reports / practice / dm_coach / translate, and the agent's
      `LLM_PROVIDER` / `LLM_PROVIDER_VOICE`.
- [ ] **Deploy bases carry the pins** so a `--full` can't wipe them (A4): verify the
      prod deploy scripts' env bases pin the providers, same as staging's
      `API_ENV_BASE` / `AGENT_ENV_BASE` do.
- [ ] **`llm_fallback_to_google` is denylisted** from all-flags-on (A5) —
      `ALL_FLAGS_ON_DENYLIST` contains it.
- [ ] **Config defaults are LiveKit-ward** (A6): dm_coach / translate default
      `gemini`, not `meta`.

### LiveKit (prod isolation + funding)
- [ ] Prod stays on the **Aimma** project (`p_4jk3pqz7u9r` /
      `wss://aimma-wt34nu3l.livekit.cloud`) with its **own bare** secrets
      (`LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET`) — **unchanged** by this promotion.
- [ ] The **room-prefix dispatch guard is present in the promoted agent build**
      (A3): `room_env_mismatch` imported and the `_request_fnc` reject in place.
      **Do not promote an agent build that lacks the guard.**
- [ ] Staging and prod stay isolated by **room prefix**: prod agent has **no**
      `ayma-staging-` prefix (unset → `ayma-`); staging agent keeps
      `LIVEKIT_ROOM_PREFIX=ayma-staging-`.
- [ ] **Never reroute off LiveKit** to handle a 429 — it's a project
      misconfiguration (A1/A2); fix the project, escalate to founder.

### Do NOT carry staging-only config into prod
- [ ] `LIVEKIT_ROOM_PREFIX=ayma-staging-` — **staging only**.
- [ ] The `_STAGING` secret mounts (`LIVEKIT_API_KEY_STAGING`, etc.) — **staging
      only**; prod keeps its bare secrets (A7).
- [ ] Staging URLs (`wss://ayma-staging-cyofszqr.livekit.cloud`,
      `ayma-staging-*` service URLs, `LIVEKIT_PROJECT_ID=p_484u2zjk8ob`).
- [ ] `EXPLORE_FIXTURE_BYPASS_UIDS`, demo/`all_flags_on` UIDs, any staging fixtures.
- [ ] Prod keeps **its own** config — promote **code**, not staging's env.

### RevenueCat
- [ ] A prod release needs the **PRODUCTION** RevenueCat key — **not** the
      debug/test key (the test key works only in debug builds; `--release` needs
      the prod key or subscriptions are OFF).

### Gates (all green before handoff)
- [ ] **Boot-smoke on-device** (logcat first-frame; A8).
- [ ] **Flutter layout matrix** green — all shards
      (`ayma_flutter/test/layout_matrix_test.dart`): zero RenderFlex overflows /
      exceptions across the size/scale/RTL/theme matrix.
- [ ] **e2e integration harness** green.
- [ ] **Store release stays behind the founder's PERSONAL pass** (hard gate) — dev
      install to the Pixel over adb only.

### Verify-before-promote (diff the two lines)
- [ ] Diff **staging ↔ main** for any reroute / `FLAG_*` / staging-only env that
      would ride along.
- [ ] Confirm the dispatch **guard is in the promoted agent** (`room_env_mismatch`
      in `_request_fnc`).
- [ ] Confirm prod's **LiveKit project + keys are unchanged** by the promotion.

### Known follow-ups — resolve or consciously defer before promoting
- [ ] **Ghost-header / router-teardown root:** `routing/app_router.dart`
      `refreshListenable` does not subscribe to auth — decide fix-vs-defer.
- [ ] **Agent-base gaps (A4):** `OPEN_WEIGHTS_BASE_URL` / `OPEN_WEIGHTS_MODEL` and
      `META_API_KEY` missing from `AGENT_ENV_BASE` / `AGENT_SECRETS` — add them or
      accept that a `--full` agent deploy drops them.
- [ ] **Founder ruling on non-LiveKit brains:** H3/H4 and D1–D6 — whether the
      Meta / open-weights (direct, off-LiveKit) surfaces and any always-direct-
      Google paths stay at all. Routing decisions here gate A4 and A6.

---

## Appendix — quick reference

- **Forbidden knobs (never set, anywhere):** `FLAG_LLM_ROUTE_*=vertex`,
  `FLAG_VOICE_PROVIDER=google`, `FLAG_LLM_FALLBACK_TO_GOOGLE=true`,
  `config/llm_routing` providers set to `vertex`/`google`.
- **Guard code:** `functions/bootstrap/livekit_token.py`
  (`STAGING_ROOM_PREFIX` / `is_staging_room_name` / `this_agent_serves_staging` /
  `room_env_mismatch`) + `functions/bootstrap/agent.py::_request_fnc`.
- **Honest-failure guards:** `VoiceSessionController` — waking (45s),
  dropped-connection, no-first-response (20s) → red error banner, never a silent
  "Listening…".
- **Commits:** staging dispatch guard `2ec98bb`; prod agent guard revision
  `ayma-agent-00139-bwc` (guard-only cherry-pick; main untouched at `9622966`).
- **Deploy scripts:** `scripts/deploy-staging.sh` (`--full` = full env replace),
  `scripts/deploy-api.sh`, `scripts/deploy-agent.sh`,
  `scripts/deploy-agent-livekit.sh`, `scripts/build-apk.sh`.
