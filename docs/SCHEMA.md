# Firestore schema (living reference)

Firestore enforces no schema, so this is the human contract for document shapes.
`docs/ARCHITECTURE.md` is the spec; this file tracks what the code actually
writes today. **Step 65** consolidates this into the full §9.1 collection
reference with composite indexes — until then it grows per phase.

## `users/{uid}`
Account/auth metadata only, written by auth/session flows, never by the AI
(§3.2). Fields land as their steps do: `session_mode`, `marketing_turn_count`,
`interview_turn_count`, `created_at`, `linked_at`, admin-claim mirror.

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
