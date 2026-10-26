# Firestore schema (living reference)

Firestore enforces no schema, so this is the human contract for document shapes.
`docs/ARCHITECTURE.md` is the spec; this file tracks what the code actually
writes today. **Step 65** consolidates this into the full §9.1 collection
reference with composite indexes — until then it grows per phase.

## `users/{uid}`
Account/auth metadata only, written by auth/session flows, never by the AI
(§3.2). Fields land as their steps do: `session_mode`, `marketing_turn_count`,
`interview_turn_count`, `created_at`, `linked_at`, admin-claim mirror.
`billing.credits_updated_at` (timestamp) is stamped whenever credits are added (start grant, selfie unlock, daily
rollover, plan grant/renewal, expiry to free); top-ups write the top-level `credits_updated_at`. The newest of the two
is the "since last credit update" start of the Plan page credit history.

## `users/{uid}/profile/main`  *(Step 7)*
Structured onboarding fields: `name`, `birthdate`, `gender`, `interested_in`,
`location`, `photo_url`. Written by the preboarding screens and the manual
fallback form.

## `users/{uid}/raw_turns/{sessionId}`  *(Step 19; §1.7 step 8, §2.2)*
One doc per chat session — the immutable interleaved voice+text window.
- `turns`: `[{ role: "user" | "ayma", text }]`
- `turn_count`: int
- `updated_at`: server timestamp
- `image_refs`: `[storageUrl]` — Storage URLs shared in the session *(planned, §2.2)*

Upserted (`merge=True`) repeatedly during a session by `/chat`, `/post-turn`,
and the agent worker's shutdown callback; always one doc.

## `users/{uid}/wiki_pages/{pageId}`  *(Step 20 schema; ingest = Step 21; §2.1)*
`pageId` is a kebab-case slug (`wiki_schema.json` → `page_id`). AI-authored,
backend-only writes (client reads are gated by visibility, never `ai_only`).
- `ai_body`: markdown — compiled source of truth, rewritten in place, never
  touched by user edits
- `visibility`: `public` | `private` | `ai_only`
- `frontmatter`: map of structured fields for the matching Pass-1 filter
- `links`: `[pageId]`
- `image_refs`: `[storageUrl]`
- `user_edits`: optional override markdown (client edit path only)
- `user_hidden`: bool (client edit path only)
- `lint_flags`: `[{ type, detail, flagged_at }]` (Lint job, §2.3)
- `source_turn_ids`: `[rawTurnId]`
- `created_at` / `updated_at`: server timestamps

Page types, id rules and visibility defaults: `functions/bootstrap/wiki_schema.json`.

## `users/{uid}/pending_questions/{questionId}`  *(Step 20 schema; queue = Step 22; §2.4)*
Task state, not compiled knowledge — never shown to the user, no visibility tier.
- `question_text`, `category` (a wiki page type), `source`: `catalog` | `followup`
- `status`: `pending` | `answered`
- `target_page`: optional `pageId` an answer would update
- `created_at` / `answered_at`

## `users/{uid}/match_candidates/{candidateUid}`  *(Step 39 schema; Pass 1 = Step 40; §5.9)*
Heuristic Pass-1 output — **no score**. Backend-only writes.
- `sourced_at`: server timestamp
- `heuristic_score`: float 0–1 (ranking hint from Pass 1, not a compatibility score)
- `reasons`: `[string]` — short structured notes (age gap, distance, shared frontmatter)

## `matches/{matchId}`  *(Step 39 schema; Pass 2 = Step 41–42; §5.4, §5.9)*
Top-level, `matchId` = `sorted_pair_key(uidA, uidB)` (`pair_key.py`). One doc, shared by both users.
- `uids`: `[uidA, uidB]` (sorted)
- `score`: float 0–1 (wiki-to-wiki compatibility; trust-flag-down-weighted)
- `user_explanation`: `{ [uid]: string }` — each from that user's perspective, no undisclosed private facts
- `ai_explanation`: string — full reasoning incl. `ai_only`; never shown to users
- `trust_flags`: `{ [uid]: [flag] }` — snapshot at scoring time (§5.5)
- `status`: `scored` → `mutual_interest` → `unmatched` | `blocked`
- `scored_at` / `updated_at`: server timestamps

## `blocks/{uid}_{blockedUid}`  *(Step 39 schema; enforced = Step 44; §5.9)*
- `blocker`, `blocked`: uids
- `created_at`: server timestamp

## `users/{uid}.trust_flags`  *(Step 39 schema; populated = Step 43; §5.5)*
`[{ type: "self_contradiction" | "face_mismatch", detail, flagged_at }]` — written by
the Lint job (§2.3) and the face-embedding check (§2.5); down-weights matching, never excludes.

## `dm_threads/{threadId}`  *(Step 46 schema; §6.6, §6.10)*
`threadId` = `sorted_pair_key(uidA, uidB)` (`dm_schema.thread_id`).
- `participants`: `[uidA, uidB]` (sorted)
- `created_at` / `last_message_at`: server timestamps
- `last_read_at`: `{ [uid]: server timestamp }`
- `hidden_for`: `[uid, …]` — set by `POST /block` (Step 52); the client's thread
  list filters these out. Messages both ways are already refused once a
  `blocks/*` doc exists.

## `dm_threads/{threadId}/messages/{messageId}`  *(Step 46 schema; §6.6)*
- `sender_uid`
- `type`: `text` | `photo` | `voice` | `shared_profile`
- `body`: text, or a Storage path (photo/voice), or a shared uid (`shared_profile`)
- `created_at`: server timestamp

## `explore` seen/passed  *(Step 49; §6.5)*
`users/{uid}/explore_passed/{otherUid}` = `{ passed_at }` — lightweight, not a block.

## Notifications  *(Step 54 schema; §7.3, §7.7, §7.8)*
- `users/{uid}.fcm_tokens`: `[token, …]` device tokens, capped at `MAX_FCM_TOKENS`
  (default 10); registered via `POST /notifications/token`, removed via
  `POST /notifications/token/remove`.
- `users/{uid}.last_push_at`: server timestamp of the last push actually sent —
  the §7.5 cooldown gate (written by the Step 55 dispatch helper).
- `users/{uid}/notifications/{id}`: `type` (`dm_message` | `mutual_match` |
  `new_scored_match` | `ayma_checkin`), `body` (preview), `deep_link`,
  `created_at`, `read`. Durable record; written by dispatch (Step 55).
- `users/{uid}/notification_prefs/main`: one bool per `type`, default `true`
  (`notifications_ops.read_prefs` fills missing keys).
Constants: `functions/bootstrap/notifications_schema.py`.

## Media & Instagram  *(Step 58 schema; §8.1, §8.3, §8.6, §9.1)*
- `users/{uid}/profile/main.photos`: `[{ media_id, order }, …]` — `order: 0` is
  the Explore-card primary and the photo-attribute source (§6.3). Add/remove/
  reorder is Step 60; deletion is a soft removal (array entry only).
- `users/{uid}.instagram_access_token`: long-lived OAuth token (Firestore is
  encrypted at rest); removed by `POST /instagram/disconnect`, which leaves
  imported photos in place.
- `users/{uid}/user_media/{id}`: `storage_path`, `source`
  (`profile` | `chat` | `dm` | `instagram_import`), `moderation_status`,
  `embedding`/`dim` (face vector, §2.5), `created_at`; Instagram imports also
  carry `instagram_id`, `permalink`, `caption`.
- Instagram bio/username + captions land in `users/{uid}/raw_turns/*` as one
  entry (feeds normal wiki ingest, §8.2). Module: `functions/bootstrap/instagram.py`.

Explore filter fields: `functions/bootstrap/explore_filter_schema.json` (Step 47).

## Consent, preferences and app control  *(all-features-on, 2026-10-25)*
- `users/{uid}.biometric_consent`: `{ consented_at, consent_version, region, source }`
  — mandatory face-matching consent, backend-authored only (`biometric_consent.py`;
  `firestore.rules` lets the client write only `onboarding_started` on `users/{uid}`).
  `consent_version` must equal `CONSENT_VERSION` to count; `region` is an ISO
  alpha-2 code or `""`; `source` is `app` | `admin_seed`. Withdrawal replaces the
  map with `{ withdrawn_at, consent_version }` and then soft-deletes the account.
  Not a knowledge field: a memory wipe keeps it.
- `users/{uid}/profile/main.qz_partner_age_min` / `qz_partner_age_max`: partner
  age range (both 18+), the questionnaire's hard-filter mirror written by
  `PUT /profile/preferences` and by Ayma's `record_answer`; the answers themselves
  live at `users/{uid}/questionnaire/{node_id}`. Explore uses the saved range as
  its default age filter.
- `users/{uid}/profile/main.distance_pref`: `"10"` | `"25"` | `"50"` | `"100"` |
  `"anywhere"` (miles); also recorded as the nearest `relocation_radius` answer.
- `users/{uid}/voice_context/current`: `{ screen, subject_uid, subject_name, note,
  detail (≤1500 chars, e.g. Explore's visible people), updated_at }` — what the
  app shows during a live call, read by the agent's `current_screen` tool.
- `users/{uid}/app_commands/pending` / `ack`: one queued UI command from Ayma
  (`open_screen` / `app_action` / `account_action`, and the `navigate` to `/dm/<threadId>`
  that `send_dm_message` queues after a send) and the client's `{ id, ok }`.
- `users/{uid}/sessions/{sessionId}.pending_dm`: `{ id, other_uid, other_name, body, at,
  quote, user_lines }`, the one DM waiting for the user's yes (5 min); `last_dm_sent`:
  `{ other_name, body, thread_id, at }`, so a repeated confirm never sends twice.
- `users/{uid}/raw_turns/{sessionId}.voice_provider`: `google` | `livekit_inference`
  (voice sessions only).
- `users/{uid}/deep_dive_runs/{report_id}`: `{ status: running|done|failed,
  started_at, finished_at }` — the caller's latest queued web search for that
  report (`deep_dive.mark_run` / `run_status`), backend-authored only. A
  `running` doc older than 10 minutes is rewritten to `failed` when read.

## Runtime config and ops  *(all-features-on)*
- `config/feature_flags`: flat flag keys (`docs/FEATURE_FLAGS.md`) plus `_history`
  (last 20 writes, for `scripts/flags.py rollback`). Backend-only.
- `app_config/{sentry,meta_integrations,dev_panel}.enabled`: client-readable mirrors
  of those flags.
- `dev_panel_attempts/{uid | ip_<sha256 prefix> | _all}`: `{ failures, locked_until }` lockout counters (`_all` also carries `window_start`)
  for `POST /dev/flags`.
- `vertex_search_usage/{YYYY-MM-DD}`: `{ count }` — the Vertex AI Search daily cap.
- `vendor_spend/*`: Muse-collected vendor figures (`vendor`, `metric`, `amount`,
  `currency`, `period`, `source_url`, `collected_by`, `fetched_at`, `note`),
  validated by `vendor_spend.py`.
