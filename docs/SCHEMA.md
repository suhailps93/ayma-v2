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
