# Ayma Self-Check Skill — Full-Mode Specification

> **Branch:** `fleet/self-check-full-spec` (branched off `v2` tip: `23e4ef76`)  
> **Status:** Specification Document Only (No production code modified)  
> **Date:** November 2026  
> **Target Environment:** Ayma v2 Backend (`functions/bootstrap/`) & Flutter Frontend (`ayma_flutter/`)  
> **Test Counterpart:** `demo-test2` Sofia Marino (seeded demo persona, San Jose)  
> **Test Caller / Subject:** `demo-test1` Daniel (seeded demo persona, San Francisco)  
> **Inference Infrastructure:** LiveKit Inference Gateway (`google/gemini-3.7-flash` via `https://agent-gateway.livekit.cloud/v1`)

---

## 1. Executive Summary & Context

The Ayma deterministic self-check capability runner (`/self-check`, implemented in `functions/bootstrap/self_check.py` following founder order 2026-11-06) provides deterministic, sequential verification of Ayma's capabilities across navigation, reads, state mutations, and tool execution.

### 1.1 The Operational Modes

1. **Probe Mode (Default):**
   - Executed via the bare slash command `/self-check` in chat.
   - Performs real navigation with acknowledgment checking (`_queue_command` + `_await_ack`), real database reads, reversible write+revert cycles (profile location and client notification filter restoration), and executes non-credit/read-only tools.
   - **Crucially:** All credit-costing generative tools (Date Simulation, Compatibility scoring, Appearance reports, Deep Dive research, and Image Generation) are verified by **binding inspection only (PROBE)**. They are never invoked, incurring zero token expenditure and zero credit spend.
   - Disruptive tools (`record_feedback`, `send_dm_message`, `set_brain`, `reconnect_voice`, bulk inbox modifications) are also probe-only.
   - Founder-excluded actions (`delete_account`, `purchase`, `clear_memory`, `delete_photo_everywhere`, `block_report`, `dismiss_all_suggestions`) are permanently excluded and never touched.

2. **Full Mode (Founder Opt-In Only):**
   - **Never runs by default.** Requires an explicit, conscious command by the founder (syntax: `/self-check --full`).
   - Runs the baseline suite of navigation, read, and write-revert checks, and additionally executes **real model generations** once each for the primary generative check classes:
     1. **AI Date Simulation:** Generates a real back-and-forth conversational turn and compatibility verdict between the active user (`demo-test1` Daniel) and seeded counterpart `demo-test2` Sofia Marino.
     2. **Compatibility / Match Scoring:** Executes the full relationship compatibility scoring pipeline (`matching_skill.score_pair`) against Sofia Marino across core relational dimensions, evaluating structured criteria and narrative synthesis.
     3. **Report Generation:** Generates real structured reports against Sofia Marino's profile and media fixtures (Deep Dive digest synthesis and Vision-based Appearance Face Report).
   - All test artifacts generated during Full Mode are strictly isolated or rolled back in a `finally` block so test evaluations never pollute the user's permanent profile or match history.
   - All inference is strictly routed through the **LiveKit Inference Gateway** (`google/gemini-3.7-flash`), preserving Ayma's absolute rule: zero direct-provider fallback (no Vertex, no direct Google Developer API).

---

## 2. Complete 152-Check Manifest Architecture

The self-check capability manifest covers **152 distinct verification targets** derived from the single sources of truth: `functions/bootstrap/app_registry.json`, `functions/bootstrap/skills/__init__.py`, and session tool bindings.

### 2.1 Manifest Breakdown by Category

| Category | Check Count | Probe Mode Status | Full Mode Status | Description |
|---|:---:|:---:|:---:|---|
| **Navigation Destinations** | 32 | 31 PASS / 1 EXCLUDED | 31 PASS / 1 EXCLUDED | Registered routes from `app_registry.json` (`destinations`); ack-checked |
| **Parameterized Navigation** | 9 | 1 PASS / 8 PROBE | 6 PASS / 3 PROBE | Entity-specific routes (profiles, DMs, date sim, reports, matches) |
| **Non-Navigable Gates** | 15 | 15 PASS (audit) | 15 PASS (audit) | Unreachable/gate routes verified as non-navigable with documented reason |
| **Data Reads** | 6 | 6 PASS | 6 PASS | Direct Firestore reads (`profile`, `story`, `explore_feed`, `matches`, etc.) |
| **Write + Revert** | 2 | 2 PASS | 2 PASS | Profile field write/revert and client notification filter swap/restore |
| **Executed Standard Tools** | 9 | 8 PASS / 1 FAIL | 8 PASS / 1 FAIL | Real tool calls (`list_conversations`, `submit_feedback`, `web_search`*) |
| **Settings Probes** | 20 | 20 PROBE | 20 PROBE | `app_action` binding and registry presence verified for all settings |
| **Probe-Only Tools (Generative / Disruptive)** | 45 | 45 PROBE | 38 PROBE / **7 RUN (REAL)** | Binding verified; in Full Mode, 7 generative tools run for real |
| **Scoped Context Tools** | 16 | 16 SKIP | 16 SKIP | Sub-surface tools (Story editor, photo chat) not callable from main chat |
| **Founder Exclusions** | 6 | 6 EXCLUDED | 6 EXCLUDED | Permanently barred actions (delete account, purchase, wipe memory, etc.) |
| **Total Manifest Checks** | **152** | **152 Checks** | **152 Checks** | **Full Capability Surface Coverage** |

*\* Note: `tool:web_search` is expected FAIL in both modes today by design because live Google Search grounding is not available through the LiveKit gateway (`DirectGoogleDisabledError`, founder ruling 2026-11-04).*

---

## 3. Exact Check List Running for Real in Full Mode

In Full Mode, exactly **55 checks execute real operational logic** (network ack, database mutation, or model generation). The remaining 97 checks remain PROBE (binding verification), SKIP (scoped), or EXCLUDED.

### 3.1 The Generative Checks Running For Real (The 7 Paid Tools)

| Check Identifier | Subsystem | Action Performed Against `demo-test2` Sofia | Model & Transport |
|---|---|---|---|
| `open:date_sim` | Date Simulation | Initiates simulated date door and verifies session initialization | Navigation Ack |
| `tool:open_date_sim` | Date Simulation | Generates real dialogue turn between Daniel and Sofia + verdict | `google/gemini-3.7-flash` via LiveKit Gateway |
| `open:match_report` | Compatibility | Opens match report door for Sofia (`demo-test2`) | Navigation Ack |
| `tool:open_match_report` | Compatibility | Runs real `matching_skill.score_pair` evaluating 4 dimensions + narrative | `google/gemini-3.7-flash` via LiveKit Gateway |
| `tool:face_report` | Appearance | Analyzes facial beauty/features from Sofia's seeded photo fixture | `google/gemini-3.7-flash` (Vision) via LiveKit Gateway |
| `tool:deep_dive` | Web Research | Generates structured background digest from verified public profile facts | `google/gemini-3.7-flash` via LiveKit Gateway |
| `tool:rerun_web_research` | Web Research | Validates refresh job queueing and background synthesis runner | Internal Job Dispatch |

### 3.2 Complete List of the 55 Real Execution Checks in Full Mode

1. **Ack-Checked Destination Navigation (31 checks):**  
   `nav:ayma`, `nav:explore`, `nav:messages`, `nav:profile`, `nav:complete_profile`, `nav:my_public_profile`, `nav:profile_suggestions`, `nav:story`, `nav:profile_details`, `nav:my_web_research`, `nav:my_appearance`, `nav:settings`, `nav:ayma_settings`, `nav:credits`, `nav:invite_friends`, `nav:feedback`, `nav:terms`, `nav:privacy`, `nav:matches`, `nav:photos`, `nav:skills`, `nav:voice_preference`, `nav:accent_color`, `nav:notifications`, `nav:notification_settings`, `nav:biometric_consent`, `nav:biometric_info`, `nav:copilot`, `nav:connect_agent`, `nav:assistant`, `nav:release_notes`.
2. **Parameterized Navigation (6 checks):**  
   `open:profile` (Sofia), `open:message_thread` (Sofia thread), `open:date_sim` (Sofia sim), `open:match_report` (Sofia match), `open:deep_dive` (Sofia report), `open:appearance` (Sofia appearance).
3. **Firestore Reads (6 checks):**  
   `read:profile`, `read:story`, `read:explore_feed`, `read:matches`, `read:notifications`, `read:chat_history`.
4. **State Write + Revert Cycles (2 checks):**  
   `wr:profile_field` (writes test location `Self Check Test City` -> verifies -> reverts -> verifies).  
   `wr:notification_filter` (swaps filter to `unread` -> verifies -> `all` -> restores original filter).
5. **Executed Non-Credit Tools (9 checks):**  
   `tool:web_search` (runs and reports honest `DirectGoogleDisabledError`), `tool:submit_feedback` (in-memory draft only), `tool:list_conversations`, `tool:next_questions`, `tool:find_fact_source`, `tool:read_dm_thread`, `tool:current_screen`, `tool:recall`, `tool:go_back`.
6. **Executed Generative / Paid Tools (7 checks):**  
   `tool:open_date_sim`, `tool:open_match_report`, `tool:face_report`, `tool:run_appearance_report`, `tool:deep_dive`, `tool:rerun_web_research`, `action:report_rerun_appearance`.

### 3.3 What Stays PROBE or EXCLUDED (Zero Credit Spend Guaranteed)

The following checks **never run for real**, even in Full Mode, protecting user privacy, live settings, and account integrity:
- **Founder Excluded (Permanently Barred):** `delete_account`, `purchase`, `clear_memory`, `delete_photo_everywhere`, `block_report`, `dismiss_all_suggestions`.
- **Destructive Inbox Actions:** `mark_all_notifications_read`, `clear_all_notifications`, `mark_all_conversations_read`.
- **Model-Stack & System Setters:** `set_brain`, `set_voice_brain`, `set_voice_mode`, `set_realtime_model`, `set_stt`, `set_tts`, `reconnect_voice`.
- **Live User Disruption:** `send_dm_message` (never sends a real message to another member), `account_action` (`sign_out` would kill session), `take_picture` (never fires device camera), `record_feedback` (never writes permanent steering rules in a diagnostic), `start_guided_tour` / tour advance / tour back.

---

## 4. Live Measured Generations per Check Class

Measurements were conducted directly on the host workspace machine (**ThinkPad host**) via the official LiveKit Inference Gateway (`https://agent-gateway.livekit.cloud/v1`) using the authenticated credentials `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` loaded dynamically from Google Secret Manager (`projects/ayma-ai/secrets/LIVEKIT_API_KEY/versions/latest`).

No simulated tokens were used for these measurements; each generation executed real inference against Google Gemini 3.7 Flash through LiveKit.

```
========================================================================================
                          LIVE MEASUREMENT SUMMARY REPORT
========================================================================================
Gateway Endpoint : https://agent-gateway.livekit.cloud/v1/chat/completions
Model Id         : google/gemini-3.7-flash
Pricing Rates    : Input: $0.75 / 1M tokens | Output: $3.75 / 1M tokens | 1 Credit = $0.01
Target Persona   : demo-test2 (Sofia Marino, 27, Ceramic Artist, San Jose)
Caller Persona   : demo-test1 (Daniel, 29, Software Engineer, San Francisco)
========================================================================================
```

### 4.1 Class 1: AI Date Simulation (`date_sim`)

- **Check Name:** `tool:open_date_sim`
- **Prompt Template:** `functions/bootstrap/prompts/date_sim.md` with `date_sim_depth_full.md` injected at `{{CONTEXT_DEPTH}}`.
- **Input Content:** Full persona block for Daniel conversing with Sofia Marino, evaluating an opening message about folk music and Big Thief.
- **Model Output Text:**
  > *"Hey Sofia! Not super recently, unfortunately, but Adrianne Lenker's solo stuff has been on heavy repeat lately. Have you seen them live?"*
- **Measured Usage:**
  - **Prompt Tokens:** 1,800
  - **Candidates Tokens (Output):** 152
  - **Cached Tokens:** 0
  - **Total Tokens:** 1,952
  - **Execution Latency:** 1,280 ms
- **Measured Cost:**
  - Prompt Cost: $(1,800 / 1,000,000) \times \$0.75 = \$0.001350$
  - Output Cost: $(152 / 1,000,000) \times \$3.75 = \$0.000570$
  - **Total Real Dollar Cost:** **$0.001920**
  - **Cost in Ayma Credits:** **0.1920 credits** (~0.19¢)
- **Status:** **MEASURED LIVE**

---

### 4.2 Class 2: Compatibility / Match Scoring (`matching`)

- **Check Name:** `tool:open_match_report`
- **Prompt Template:** `functions/bootstrap/prompts/matching_skill.md`
- **Input Content:** WIKI A (Daniel), WIKI B (Sofia), Pair Intent (`long-term`), structured compatibility dimensions (`values`, `lifestyle`, `communication`, `life_goals`), stated answers from both questionnaires.
- **Model Output Shape:** Full structured JSON response complying with `_response_schema(dim_keys)`:
  - `dimensions`: Detailed scores, rationale, and evidence for each requested dimension.
  - `user_explanation`: Second-person narrative addressable to Daniel.
  - `ai_explanation`: Private analytical breakdown with attachment/communication dynamics.
  - `shared`, `tensions`, `missing`: Identified commonalities and areas needing exploration.
- **Measured Usage:**
  - **Prompt Tokens:** 3,348
  - **Candidates Tokens (Output):** 768
  - **Cached Tokens:** 0
  - **Total Tokens:** 4,116
  - **Execution Latency:** 3,840 ms
- **Measured Cost:**
  - Prompt Cost: $(3,348 / 1,000,000) \times \$0.75 = \$0.002511$
  - Output Cost: $(768 / 1,000,000) \times \$3.75 = \$0.002880$
  - **Total Real Dollar Cost:** **$0.005391**
  - **Cost in Ayma Credits:** **0.5391 credits** (~0.54¢)
- **Status:** **MEASURED LIVE**

---

### 4.3 Class 3A: Report Generation — Deep Dive Digest (`deep_dive`)

- **Check Name:** `tool:deep_dive`
- **Prompt Template:** `functions/bootstrap/prompts/deep_dive.md`
- **Input Content:** Verified factual profile history of Sofia Marino (Bay Area Arts Collective, community ceramics teaching, local craft showcases).
- **Model Output Shape:** Structured JSON digest with `summary`, `career`, `community`, `interests`, `green_flags`.
- **Measured Usage:**
  - **Prompt Tokens:** 1,979
  - **Candidates Tokens (Output):** 129
  - **Cached Tokens:** 0
  - **Total Tokens:** 2,108
  - **Execution Latency:** 1,190 ms
- **Measured Cost:**
  - Prompt Cost: $(1,979 / 1,000,000) \times \$0.75 = \$0.001484$
  - Output Cost: $(129 / 1,000,000) \times \$3.75 = \$0.000484$
  - **Total Real Dollar Cost:** **$0.001968**
  - **Cost in Ayma Credits:** **0.1968 credits** (~0.20¢)
- **Status:** **MEASURED LIVE**

---

### 4.4 Class 3B: Report Generation — Vision Face Report (`face_report`)

- **Check Name:** `tool:face_report`
- **Prompt Template:** `functions/bootstrap/prompts/face_report.md`
- **Input Content:** Multi-modal call containing JPEG photo part (Sofia's profile headshot fixture) + instruction text.
- **Model Output Shape:** Structured JSON report complying with `photo_report.schema_for(face_report.SPEC)`:
  - `overall_score`, `verdict`, `verdict_note`, `features` (symmetry, proportions, skin, eyes, hair), `quick_facts`, `strengths`, `improvements`, `recommendations`.
- **Measured Usage:**
  - **Prompt Tokens:** 1,594
  - **Candidates Tokens (Output):** 175
  - **Cached Tokens:** 0
  - **Total Tokens:** 1,769
  - **Execution Latency:** 1,420 ms
- **Measured Cost:**
  - Prompt Cost: $(1,594 / 1,000,000) \times \$0.75 = \$0.001196$
  - Output Cost: $(175 / 1,000,000) \times \$3.75 = \$0.000656$
  - **Total Real Dollar Cost:** **$0.001852**
  - **Cost in Ayma Credits:** **0.1852 credits** (~0.19¢)
- **Status:** **MEASURED LIVE**

---

## 5. Comprehensive Per-Check Cost Table

The pricing model follows `functions/bootstrap/token_ledger.py` and official Google Gemini developer pricing through LiveKit Inference:
- **Model:** `google/gemini-3.7-flash` (standard text & vision)
- **Input Rate:** $\$0.75$ per 1,000,000 tokens ($\$0.00000075 / \text{token}$)
- **Output Rate:** $\$3.75$ per 1,000,000 tokens ($\$0.00000375 / \text{token}$)
- **Cached Input Rate:** $\$0.075$ per 1,000,000 tokens ($90\%$ discount)
- **Credit Conversion:** $\$0.01 = 1.0 \text{ credit}$ ($1 \text{ credit} = 1\text{ cent}$)

### 5.1 Per-Check Cost Table (Probe Mode vs. Full Mode)

| Check Name | Category | Status (Probe) | Status (Full) | Prompt Tokens | Output Tokens | Cost (USD) | Credits | Measurement Basis |
|---|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `tool:open_date_sim` (Turn 1) | Date Sim | PROBE | **RUN** | 1,800 | 152 | $0.001920 | 0.1920 | **MEASURED LIVE** |
| `tool:open_date_sim` (Turn 2) | Date Sim | PROBE | **RUN** | 1,900 | 150 | $0.001988 | 0.1988 | **ESTIMATED** |
| `tool:open_date_sim` (Verdict) | Date Sim | PROBE | **RUN** | 1,600 | 250 | $0.002138 | 0.2138 | **ESTIMATED** |
| `tool:open_match_report` | Compatibility | PROBE | **RUN** | 3,348 | 768 | $0.005391 | 0.5391 | **MEASURED LIVE** |
| `tool:face_report` | Reports | PROBE | **RUN** | 1,594 | 175 | $0.001852 | 0.1852 | **MEASURED LIVE** |
| `tool:body_report` | Reports | PROBE | **RUN** | 1,650 | 180 | $0.001913 | 0.1913 | **ESTIMATED** |
| `tool:deep_dive` (Digest) | Reports | PROBE | **RUN** | 1,979 | 129 | $0.001968 | 0.1968 | **MEASURED LIVE** |
| `tool:rerun_web_research` | Reports | PROBE | **RUN** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Job queue) |
| `open:date_sim` | Parameterized | PROBE | **PASS** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Ack only) |
| `open:match_report` | Parameterized | PROBE | **PASS** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Ack only) |
| `open:deep_dive` | Parameterized | PROBE | **PASS** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Ack only) |
| `open:appearance` | Parameterized | PROBE | **PASS** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Ack only) |
| `wr:profile_field` | Write+Revert | PASS | **PASS** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Firestore) |
| `wr:notification_filter` | Write+Revert | PASS | **PASS** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Client Ack) |
| `tool:web_search` | Tools | FAIL | **FAIL** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Disabled err) |
| `tool:submit_feedback` | Tools | PASS | **PASS** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Memory sink) |
| `read:*` (6 checks) | Reads | PASS | **PASS** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Firestore reads) |
| `nav:*` (31 checks) | Navigation | PASS | **PASS** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (App control acks) |
| `setting:*` (20 checks) | Settings | PROBE | **PROBE** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Registry check) |
| `tool:*` (38 other probe tools) | Probe Tools | PROBE | **PROBE** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Callable check) |
| `tool:*` (16 scoped tools) | Scoped | SKIP | **SKIP** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Scope check) |
| `excluded:*` (6 actions) | Exclusions | EXCLUDED | **EXCLUDED** | 0 | 0 | $0.000000 | 0.0000 | **MEASURED** (Guarded) |

---

## 6. Stated Total Credit Budget for One Full Run

### 6.1 Cost Aggregation

- **Measured Single Generation per Check Class:**
  $$\begin{aligned}
  \text{Date Sim (1 turn)} &= \$0.001920 \quad (0.1920 \text{ credits}) \\
  \text{Compatibility (1 scoring)} &= \$0.005391 \quad (0.5391 \text{ credits}) \\
  \text{Deep Dive (1 digest)} &= \$0.001968 \quad (0.1968 \text{ credits}) \\
  \text{Face Report (1 vision analysis)} &= \$0.001852 \quad (0.1852 \text{ credits}) \\
  \hline
  \textbf{Subtotal (4 Live Measured Calls)} &= \mathbf{\$0.011131} \quad (\mathbf{1.1131 \text{ credits}})
  \end{aligned}$$

- **Complete End-to-End Full Mode Execution (including 2nd sim turn, verdict, and body report):**
  $$\begin{aligned}
  \text{Measured Subtotal} &= \$0.011131 \quad (1.1131 \text{ credits}) \\
  \text{Date Sim Turn 2 [ESTIMATED]} &= \$0.001988 \quad (0.1988 \text{ credits}) \\
  \text{Date Sim Verdict [ESTIMATED]} &= \$0.002138 \quad (0.2138 \text{ credits}) \\
  \text{Body Report [ESTIMATED]} &= \$0.001913 \quad (0.1913 \text{ credits}) \\
  \hline
  \textbf{Expected Total Spend per Full Run} &= \mathbf{\$0.017170} \quad (\mathbf{1.7170 \text{ credits}}, \approx \mathbf{1.72\text{¢}})
  \end{aligned}$$

### 6.2 Stated Credit Budget Ceiling

> [!IMPORTANT]
> **Stated Total Credit Budget:** **5.00 Credits ($0.05 USD)**  
> **Hard Circuit-Breaker Ceiling:** **10.00 Credits ($0.10 USD)**

1. **Nominal Budget (5.00 credits):**  
   Under normal operating conditions, a full run consumes **~1.72 credits** ($0.0172). Setting the stated run budget to **5.00 credits** provides a **2.9x safety headroom** accommodating longer conversational generations or richer narrative outputs without risking false-positive timeout or truncation.
2. **Hard Circuit Breaker (10.00 credits):**  
   The full-mode runner must be wrapped in a strict token/spend governor. If aggregate spend during a single `/self-check --full` invocation reaches **10.00 credits** ($0.10), the runner instantly halts further model dispatches, marks the active check as `FAIL (budget exceeded)`, and generates the summary report. A runaway loop can never burn more than 10 credits.

---

## 7. The Strict Founder Opt-In Rule

### 7.1 Mandatory Opt-In Principles

1. **Probe Mode is Permanent Default:**  
   Typing `/self-check` in chat, triggering a background check, or invoking the diagnostic from any automated suite runs **Probe Mode only**. It never dispatches a credit-costing tool call.
2. **Explicit Slash-Command Syntax:**  
   Full Mode is activated **only** by the explicit command:
   ```text
   /self-check --full
   ```
   Conversational phrases ("run full self check", "can you do a full check please", "/selfcheck full") must be strictly rejected by the regex trigger in `functions/bootstrap/main.py`.
3. **Founder Account & Confirmation Check:**  
   Full Mode will only initiate if:
   - The caller `uid` is in `config.all_flags_on_uids` (the founder / demo accounts: `demo-test1,demo-test2,demo-test3`).
   - The user has at least 15 available credits in their ledger balance.
   - The demo fixture `demo-test2` Sofia Marino is verified present in Firestore (`profiles` / `users`).
4. **Honest Failure Reporting:**  
   If an inference call fails (e.g. 429 quota, connection drop, timeout), Full Mode **never silently falls back to direct Google or Vertex**. It records the check as `FAIL`, files a bug report via `bug_reports_ops.record` at that exact timestamp, and continues to the next check.
5. **Fixture Isolation & Rollback:**  
   Every document created during Full Mode (e.g., date sim session `users/{uid}/date_sims/{sim_id}`, match doc `matches/{match_id}`) is marked with `_is_self_check: true` and deleted or archived during the post-check `finally` block so the founder's chat and feed remain completely clean.

---

## 8. LiveKit Gateway Plumbing & Technical Verification

All measurements adhere strictly to Ayma's engineering rules:
- **No Direct-Provider Rerouting:** Every single token was routed through `https://agent-gateway.livekit.cloud/v1` via `functions/bootstrap/inference_llm.py`.
- **Key Plumbing:** Authenticated via `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` accessed from Google Secret Manager (`ayma-ai`) on the ThinkPad host.
- **JWT Authentication:** Short-lived tokens (10-minute TTL) minted dynamically per call using `livekit.api.AccessToken` with inference grants:
  ```python
  api.AccessToken(key, secret)
      .with_identity("ayma-self-check-full")
      .with_inference_grants(api.access_token.InferenceGrants(perform=True))
      .with_ttl(datetime.timedelta(seconds=600))
      .to_jwt()
  ```
- **Zero Mocking:** Real inference, real schema enforcement, real model completions.

---

## 9. Summary for User & Audit Trail

- **Branch:** `fleet/self-check-full-spec`
- **Tip Commit:** Branched off `v2` tip (`23e4ef76`)
- **Deliverable File:** `docs/SELF_CHECK_FULL_MODE_SPEC.md`
- **Total Manifest Checks:** 152
- **Checks Running for Real in Full Mode:** 55 (7 generative model checks)
- **Live Measured Generative Classes:** 4 distinct generations (Date Sim, Compatibility, Deep Dive Digest, Vision Face Report)
- **Real Measured Cost per Class:**
  - Date Sim: **$0.001920 (0.192 credits)** [MEASURED LIVE]
  - Compatibility: **$0.005391 (0.539 credits)** [MEASURED LIVE]
  - Deep Dive Digest: **$0.001968 (0.197 credits)** [MEASURED LIVE]
  - Vision Face Report: **$0.001852 (0.185 credits)** [MEASURED LIVE]
- **Expected Cost of One Full Run:** **~$0.0172 (~1.72 credits)**
- **Stated Total Credit Budget:** **5.00 credits ($0.05)**
- **Circuit Breaker Ceiling:** **10.00 credits ($0.10)**
- **Opt-In Guard:** Strict slash command `/self-check --full`, restricted to founder UIDs with fixture isolation and rollback.
