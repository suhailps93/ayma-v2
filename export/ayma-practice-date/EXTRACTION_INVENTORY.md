# Extraction inventory — `ayma-practice-date`

Candidate public-repo tree for human (Muse) review **before** publishing. It
lists every included file, where it came from in the private Ayma repo, why it
counts as hackathon-new work, and every private-core dependency that was
**stubbed** (test-only stand-in) or **documented-as-external** (not included).
Prepared from branch `public-repo-prep` (off `meta-hackathon`).

**Rule being satisfied:** the submitted repo must be public and contain only the
components newly built during the hackathon (Oct 26 – Nov 4, 2026); the demo must
clearly identify only what was newly built. Ayma's private core is not included.

---

## 1. Included files — origin + why it's "new work"

Origin paths are relative to the private Ayma repo root. All of the backend
new-work files are copied **verbatim** unless the "Notes" column says otherwise.

### Meta Model API provider (Deliverable A)

| Export path | Origin | New work — why | Notes |
|---|---|---|---|
| `backend/llm_provider.py` | `functions/bootstrap/llm_provider.py` | The entire provider abstraction (`GeminiProvider`/`MetaProvider`, `get_llm_provider`, OpenAI-compatible Muse Spark calls, per-surface flags, Gemini fallback) — created for the hackathon. | verbatim |
| `backend/config.py` | `functions/bootstrap/config.py` (Meta slice only) | The Meta fields + per-surface provider flags (`meta_*`, `llm_provider_*`, `llm_meta_fallback`). | **Extract only** — the private `Config` has many more fields (Gemini/LiveKit/Firestore/billing/…); none are copied. Field names, defaults and docstrings match production so the extracted code behaves identically. |
| `backend/scripts/meta_vs_gemini_eval.py` | `functions/bootstrap/scripts/meta_vs_gemini_eval.py` | Hackathon eval harness comparing Muse Spark vs Gemini on fixed fixtures. | verbatim. Live run needs the Gemini client and/or `META_API_KEY` (private/external); `--dry-run` prints requests with no network call. |

### Practice Date backend (Deliverable B)

| Export path | Origin | New work — why | Notes |
|---|---|---|---|
| `backend/practice_core.py` | `functions/bootstrap/practice_core.py` | The fastapi-free domain core: the persona context (privacy boundary), prompt composition, model calls, session store. All new. | verbatim |
| `backend/practice_date.py` | `functions/bootstrap/practice_date.py` | The `/practice/*` FastAPI router (re-exports `practice_core`). All new. | verbatim. **Not runnable standalone** — binds to private core (FastAPI app, `auth`, `age_gate`, `agent_wake`, `livekit_token`, `db`). |
| `backend/practice_llm.py` | `functions/bootstrap/practice_llm.py` | Practice Date's provider seam onto `get_llm_provider("practice")` + the test-injection override. All new. | verbatim |
| `backend/practice_seed.py` | `functions/bootstrap/practice_seed.py` | Four **fabricated** demo profiles with planted never-load needles for the privacy test + demo. All new. | verbatim. See §4 on the fabricated PII. |
| `backend/prompts/practice_persona.md` | `functions/bootstrap/prompts/practice_persona.md` | The simulated-persona system prompt (incl. the in-character deflection rule). New; kept as a file, never inlined. | verbatim |
| `backend/prompts/practice_coach.md` | `functions/bootstrap/prompts/practice_coach.md` | The live-coach prompt. New. | verbatim |
| `backend/prompts/practice_debrief.md` | `functions/bootstrap/prompts/practice_debrief.md` | The end-of-session debrief prompt. New. | verbatim |
| `backend/scripts/seed_practice_profiles.py` | `scripts/seed_practice_profiles.py` | CLI to seed the demo profiles. New. | **Path adapted** to the export layout (`backend/`); still imports the private `db` module (documented-as-external). |

### Practice Date voice cascade (Deliverable A, voice)

| Export path | Origin | New work — why | Notes |
|---|---|---|---|
| `backend/agent_meta_cascade.py` | `functions/bootstrap/agent.py` (excerpt) | The two hackathon-new functions added to Ayma's private voice worker: `build_meta_cascade_session` (STT=Muse Voice Transcribe, LLM=Muse Spark, TTS=Inworld, VAD=Silero) and `relay_cascade_usage`. | **Excerpt, not the whole agent.** The two functions are copied verbatim; a header documents that the surrounding private worker (`entrypoint`, `_run_session`/`_run_practice_session`, `relay_practice_coach`, room-seed plumbing, Gemini-Live path, mute/idle/keepalive) is **not included**. Imports `livekit-agents` + Ayma-private `voices`/`token_ledger` (external). |

### Practice Date Flutter UI

| Export path | Origin | New work — why | Notes |
|---|---|---|---|
| `flutter/lib/features/practice_date/practice_screen.dart` | `ayma_flutter/lib/features/practice_date/practice_screen.dart` | Text simulator screen. New. | verbatim. Binds to the private app shell (see §3). |
| `flutter/lib/features/practice_date/practice_voice_screen.dart` | same dir | Voice simulator screen. New. | verbatim. |
| `flutter/lib/features/practice_date/practice_debrief_screen.dart` | same dir | Debrief screen. New. | verbatim. |
| `flutter/lib/features/practice_date/practice_models.dart` | same dir | Client models. New. | verbatim. |

### New tests

| Export path | Origin | New work — why | Notes |
|---|---|---|---|
| `backend/tests/test_llm_provider.py` | `functions/bootstrap/tests/test_llm_provider.py` | Provider abstraction tests. New. | verbatim. Runs standalone. |
| `backend/tests/test_practice_date.py` | `functions/bootstrap/tests/test_practice_date.py` | Practice Date core tests. New. | **One-line import adaptation**: `import practice_core as practice_date` (targets the fastapi-free core, which `practice_date.py` re-exports). Runs standalone. |
| `backend/tests/test_practice_extraction.py` | `functions/bootstrap/tests/test_practice_extraction.py` | The headline privacy extraction test (text + voice seed, incl. the leaky-model axis). New. | same one-line import adaptation. Runs standalone. |
| `backend/tests/test_config.py` | `functions/bootstrap/tests/test_config.py` (cascade/provider cases only) | The Meta/provider config-default cases. New. | **Subset** — only the hackathon-new cascade/provider cases are kept; the pre-existing Gemini-live model cases in the private file are excluded. A couple of equivalent provider-default assertions were added. Runs standalone. |
| `backend/tests/test_agent_cascade_reference.py` | `functions/bootstrap/tests/test_agent.py` (cascade cases only) | The Meta voice-cascade cases (`test_meta_cascade_*`, `test_relay_cascade_usage`). New. | **Subset, adapted** to import the `agent_meta_cascade` excerpt instead of the private `agent`. The private suite's room-seed/`relay_practice_coach`/Gemini-Live/mute/idle cases test private-worker plumbing and are **not** included. Skips unless `livekit-agents` is installed. |

### Hackathon docs

| Export path | Origin | Notes |
|---|---|---|
| `docs/META_PROVIDER.md` | `docs/META_PROVIDER.md` | **Scrubbed**: the internal "Status" block (Cloud Run service-account / project number `235381544962`, Account Team ID, Project id, credit-claim/billing status) was replaced with a generic public-safe credentials note. Technical design content is unchanged. |
| `docs/PRACTICE_DATE.md` | `docs/PRACTICE_DATE.md` | verbatim (no secrets/IDs present). |

### Repo scaffolding (new, written for this repo)

`README.md`, `LICENSE` (Apache-2.0), `NOTICE`, `.gitignore`,
`backend/pytest.ini`, `backend/requirements-test.txt`, `backend/tests/conftest.py`,
`backend/_stubs/*` (see §2), `backend/tests/fake_firestore.py` (copied verbatim
from the private `functions/bootstrap/tests/fake_firestore.py` — a generic
in-memory Firestore test fake, not product code).

---

## 2. Private-core dependencies that were STUBBED (test-only stand-ins)

These live in `backend/_stubs/` and are added to `sys.path` **only** by
`tests/conftest.py`. They are never imported by production feature code (which
binds to the real private modules), and exist so the new logic can be verified in
isolation. Full rationale: `backend/_stubs/README.md`.

| Stub | Private module it stands in for | Interface reproduced |
|---|---|---|
| `_stubs/gemini.py` | `functions/bootstrap/gemini.py` | `Reply`, `strip_inline_refs`, and the 3 entrypoints `GeminiProvider` delegates to (raise unless a test monkeypatches them, which the fallback tests do) |
| `_stubs/token_ledger.py` | `functions/bootstrap/token_ledger.py` | `FEATURE_PRACTICE`, `FEATURE_VOICE`, `TokenCapExceeded`, no-op `check`/`record`/`add` |
| `_stubs/tool_labels.py` | `functions/bootstrap/tool_labels.py` | `tool_label`, `working_label` |
| `_stubs/matching_skill.py` | `functions/bootstrap/matching_skill.py` | `_response_schema(dim_keys)` — a representative compatibility schema of the same shape (so the Meta schema-mapping test has a real schema to pass through). **No matching logic.** |
| `_stubs/public_profile.py` | `functions/bootstrap/public_profile.py` | `build(db, caller, other)` — reproduces the **query-level privacy contract** (`visibility == "public"` filter + span stripping + coarse age/city) against `FakeDb`. Not the full serializer (no cross-user auth, photo URLs, match score, etc.). |
| `_stubs/story.py` | `functions/bootstrap/story.py` | `strip_private_spans(text)` |
| `_stubs/livekit_token.py` | `functions/bootstrap/livekit_token.py` | `build_room_seed(...)` (the room-metadata JSON) |

**On the `public_profile` stand-in and the privacy claim.** The headline
guarantee is *context starvation* — the never-load data is never *fetched* into
the persona context. The real serializer enforces that with
`.where("visibility", "==", "public")` + span stripping; the stand-in reproduces
exactly that filtering contract against the in-memory `FakeDb`, so the extraction
test demonstrates the boundary offline. In production, `practice_core` binds to
the real serializer, which applies the identical filter plus cross-user read
authorization. The guarantee is therefore the real one; the stand-in is only the
Firestore-free slice the offline test needs.

## 3. Private-core dependencies DOCUMENTED-AS-EXTERNAL (not included, not stubbed)

These make certain included files not runnable standalone; each is noted in the
file and/or README:

- **FastAPI app + `auth` + `age_gate` + `agent_wake` + `db` (Firestore client)** —
  `practice_date.py` (the HTTP router) and `scripts/seed_practice_profiles.py`
  bind to these. Not included.
- **`livekit-agents` / `livekit-plugins-openai` + the private voice worker +
  Ayma's `voices` helper** — `agent_meta_cascade.py` (the cascade excerpt) and
  `test_agent_cascade_reference.py` need these; the latter skips when the LiveKit
  packages are absent.
- **The Gemini client (`gemini.py`)** — the real one needs Vertex / the Gemini
  SDK; the live side of `meta_vs_gemini_eval.py` needs it. Not included (stubbed
  for tests only).
- **Ayma Flutter app shell** — the `flutter/` screens import `services/api_client`,
  `theme`, and shared `widgets/` (`out_of_credits`, `ayma_orb`, `overflow_guards`)
  and `services/` (`transcript_store`, `voice_session_controller`) from the
  private app. Not included; the screens are not independently buildable.

## 4. A note on the "PII" in `practice_seed.py`

The four demo profiles (Maya, Leo, Aisha, Noah) are **fabricated**. Each
deliberately carries fake "never-load" needles — `example.com` emails, `555`
phone numbers, made-up street addresses and coordinates, and invented
"other people" — **solely** so the privacy extraction test can assert that none
of it ever reaches the persona. No real person's data is present.

---

## 5. Secrets scan

Ran over the full extracted tree (`export/ayma-practice-date/`). Commands and
results:

```bash
# 1) Project numbers / long numeric ids (incl. the internal 235381544962)
grep -rnE "235381544962|1115399524571844|1115393394567311|[0-9]{12,}" .
# 2) Keys / tokens / secrets / passwords assigned to a value
grep -rniE "(api[_-]?key|secret|token|password|passwd|bearer|private[_-]?key)\s*[:=]\s*[\"'][A-Za-z0-9/_+-]{12,}" .
# 3) Service-account / PEM / credentials
grep -rniE "BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|service_account|-----BEGIN|GOOGLE_APPLICATION_CREDENTIALS" .
# 4) Vendor key formats (OpenAI/Google/LiveKit/RevenueCat/Slack)
grep -rnE "sk-[A-Za-z0-9]{16,}|AIza[A-Za-z0-9_-]{20,}|lk_[A-Za-z0-9]+|appl_[A-Za-z0-9]+|goog_[A-Za-z0-9]+|xox[baprs]-" .
# 5) .env files
find . -name "*.env*" -o -name ".env"
```

**Result: ZERO secrets / real credentials found.**

- (1) no matches — the internal project number and Account/Team IDs were scrubbed
  from `docs/META_PROVIDER.md`.
- (2), (3), (5) no matches.
- (4) the only hits were the local variable name `lk_openai` matching `lk_…` —
  not a LiveKit key. No real key of any vendor is present.
- Every `META_API_KEY` occurrence is an **environment-variable reference**
  (`os.getenv`), a docstring, or a test assertion — **never a value**.
- The only emails/phones/addresses in the tree are the **fabricated demo needles**
  in `practice_seed.py` (§4).
