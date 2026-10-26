# `_stubs/` — minimal stand-ins for Ayma's private core (tests only)

The hackathon components import a handful of modules that live in Ayma's
**private** backend and are deliberately **not** part of this public repo
(matching internals, auth, Firestore wiring, the Gemini client, the real
lifetime-credit ledger, the voice-room plumbing). Copying those files here would
defeat the point of the public subset.

Instead, this directory provides **small, clearly-labelled stand-ins** that
implement only the narrow interface the extracted code and the self-contained
tests exercise. They are added to `sys.path` **only** by `tests/conftest.py`, so
they are used **only when running the tests in isolation** — never imported by
the production feature code, which binds to the real private modules in Ayma's
backend.

| Stub | Stands in for | Interface reproduced (only this) |
|---|---|---|
| `gemini.py` | Ayma's Gemini client (`gemini.py`) | `Reply` dataclass, `strip_inline_refs`, and `generate_json` / `generate_reply` / `generate_reply_events` entrypoints (raise unless a test monkeypatches them, which the fallback tests do) |
| `token_ledger.py` | Ayma's lifetime-credit ledger | `FEATURE_PRACTICE`, `FEATURE_VOICE`, `TokenCapExceeded`, no-op `check` / `record` / `add` |
| `tool_labels.py` | user-facing tool-label map | `tool_label(name)`, `working_label(name)` |
| `matching_skill.py` | the private matching skill | `_response_schema(dim_keys)` — a representative compatibility JSON schema, used only so the Meta provider's schema-mapping test has a real schema shape to pass through |
| `public_profile.py` | the viewer-visible profile serializer | `build(db, caller, other)` reproducing the **query-level privacy contract**: wiki read filtered to `visibility == "public"`, `{{private}}`/`{{ai_only}}` spans stripped, deleted/self handling, coarse city + computed age only |
| `story.py` | the Story span parser | `strip_private_spans(text)` |
| `livekit_token.py` | the voice-room seed builder | `build_room_seed(...)` producing the room-metadata JSON |

**Why the `public_profile` stand-in still proves the privacy claim.** The
headline guarantee is *context starvation* — the never-load data is never
*fetched* into the persona context. The real serializer enforces that by reading
wiki with `.where("visibility", "==", "public")` and stripping private spans. The
stand-in reproduces exactly that filtering contract against the in-memory
`FakeDb`, so the extraction test demonstrates the boundary offline. In
production, `practice_core.build_persona_context` binds to Ayma's real
`public_profile.build`, which applies the identical filter plus cross-user read
authorization. See `EXTRACTION_INVENTORY.md`.
