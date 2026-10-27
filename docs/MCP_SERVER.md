# Ayma MCP server — bring your own agent

The Ayma MCP server is a **bring-your-own-agent** interface. An external MCP
client (e.g. Claude Desktop/Code, or any Model Context Protocol client)
authorises as one specific Ayma user and, from then on, **the client's own model
does all the reasoning**. The Ayma MCP server exposes Ayma's skills + data as MCP
tools — profile, matches, DMs, persona context — so the client is the *brain*
and Ayma is the *hands and memory*.

It is mounted at `/mcp` on the existing FastAPI app (`ayma-api`, Cloud Run) via
the official `mcp` Python SDK's streamable-HTTP transport, and it is gated behind
the `mcp_server` feature flag, **default OFF**.

## Core principle — zero Ayma LLM spend

**No exposed MCP tool calls Ayma's own chat / reasoning LLM.** Anything that
needs generation — a bio, a story rewrite, a DM reply, a practice line — is
composed by the **client's** model and passed in as plain text to a save/send
tool. Tools do data ops, reads, searches and *gated writes* only.

The one model call anywhere in the tool surface is `dm_moderation.moderate` on an
outgoing DM: a safety classifier (cents), run with `enforce_cap=False` and not
attributed to the user — the exact same moderation the in-app DM send already
runs. Embeddings for matching and vision/moderation may still run server-side
(cents); those are acceptable. No generative chat/reasoning call is ever made on
behalf of a connected agent.

Why it matters: a connected agent could otherwise drive unbounded Gemini spend on
Ayma's bill. By construction, the marginal LLM cost of any MCP tool call is zero
(moderation aside). Tool calls are still metered for observability via
`token_ledger.record_mcp_tool_call`, which writes a **separate, cost-free**
`users/{uid}.mcp_usage` counter and deliberately never touches `token_usage` or
the credit balance.

## Architecture

```
External MCP client (Claude)          Ayma app (Flutter)
        │  the client's model = brain         │  user already signed in
        │                                      │
        │ 1. POST /mcp/oauth/device_authorization
        ▼                                      │
  device_code + short user_code               │
        │                                      │ 2. user opens
        │   (client shows user_code)           │    Profile → Connect an agent,
        │                                      │    types the code, approves
        │                                      ▼
        │                         POST /mcp/connect/approve  (Firebase ID token)
        │                         → binds device_code to this uid
        │ 3. poll POST /mcp/oauth/token
        ▼
  opaque per-user access token (Bearer)
        │
        │ 4. MCP streamable-HTTP, Authorization: Bearer <token>
        ▼
  /mcp  ── _McpAuthASGI ──▶ MCPServer tools ──▶ Firestore / existing skills
         (flag gate 503,       (scope, 18+,        (reads + gated writes;
          token auth 401,       moderation,         NO Ayma chat LLM)
          per-token 429)        no-PII, scoping)
```

Files (all in `functions/bootstrap/`):

| File | Role |
|---|---|
| `mcp_server.py` | Builds the `MCPServer`, registers the tools, the `_McpAuthASGI` auth wrapper, the OAuth/approval Starlette routes, the composed `/mcp` ASGI app, and the session-manager lifespan. |
| `mcp_oauth.py` | OAuth 2.1 Device Authorization Grant; opaque, revocable, Firestore-validated access tokens (no signing key). FastAPI-free. |
| `mcp_tools.py` | The tool implementations. Each re-enforces every gate server-side. FastAPI-free. |
| `token_ledger.record_mcp_tool_call` | Cost-free observability meter (`users/{uid}.mcp_usage`). |

Flutter: `lib/screens/connect_agent_screen.dart` (the "Connect an agent"
approval + connected-agents management) and `lib/services/mcp_connect_service.dart`.
The screen leads with a numbered **how-to-connect** block — add Ayma's MCP
server (`{Env.apiBaseUrl}/mcp`, shown live and copyable, never hardcoded) in
your assistant, start it, type the short code it shows, Review, Approve — plus a
**Learn more** sheet (the device flow, the access granted, and the 18+ /
moderation / scope / "only approve a code you started yourself" safety notes).
If the server reports the feature off (503), the screen shows an honest note
that a code can be entered but won't connect until the flag is on, rather than
letting the attempt fail quietly.

Mounting (in `main.py`, additive): `app.mount("/mcp", mcp_server.asgi_app)` plus
a startup/shutdown that runs the streamable-HTTP session manager's lifespan (a
mounted sub-app's lifespan is not run by the parent). The existing `RateLimiter`
ASGI middleware already covers the `/mcp` prefix (`rate_mcp`, default
`120/minute` per client), *in addition to* the per-token limit in the wrapper.

### Why these choices

- **Streamable-HTTP, stateless + JSON responses.** Works with Cloud Run
  scale-to-zero; each JSON-RPC request is independent. This is exactly the
  transport a standard MCP client speaks.
- **Opaque tokens, not JWTs.** An access token is a random string
  (`aymcp_…`); only its SHA-256 hash is stored (`mcp_tokens/{hash}`), so the raw
  token is never persisted. Validation is a Firestore lookup, which means **no
  signing key / secret is required** and a token is revoked instantly by setting
  `revoked`. A 10-second in-process cache keeps the hot path to ~zero reads.
- **Approval happens in-app, not in a browser.** The user is already
  Firebase-authenticated in the Ayma app, so binding the device code to their
  uid is a single authenticated call — no web login page, no credential sharing.
- **The flag gates the whole surface.** When `mcp_server` is off, no connection
  can be authorized and no tool call succeeds — the MCP endpoint and the
  `device_authorization` / `token` / `approve` endpoints all answer
  `503 mcp_disabled` (listing/revoking already-connected agents deliberately
  stays available so users can clean up after the feature is turned off).
  Merging this code exposes nothing until the founder flips the flag (`scripts/flags.py set mcp_server=true --yes`, effective in ~60 s, no
  redeploy). The flag needs no secret.

## Auth flow (OAuth 2.1 Device Authorization Grant, RFC 8628)

Endpoints (all under `/mcp`):

| Endpoint | Method | Auth | Purpose |
|---|---|---|---|
| `/mcp/oauth/device_authorization` | POST | none | Start a flow. Body: `client_id`, optional `scope`. Returns `device_code`, `user_code`, `verification_uri`, `verification_uri_complete`, `expires_in` (600s), `interval` (5s). |
| `/mcp/oauth/token` | POST | none | Poll. `grant_type=urn:ietf:params:oauth:grant-type:device_code`, `device_code`, `client_id`. Returns `access_token` once approved; else `authorization_pending` / `slow_down` / `access_denied` / `expired_token`. A device code is single-use. |
| `/mcp/oauth/revoke` | POST | token | RFC 7009 revocation of a raw token. |
| `/mcp/connect` | GET | none | Tiny HTML page telling the user to approve in the Ayma app. |
| `/mcp/connect/approve` | POST | **Firebase ID token** | The in-app approval. Body: `user_code`, `approve` (default true), optional `scopes` (can only *narrow* the request). Binds the device code to the caller's uid. |
| `/mcp/connect/pending` | GET | Firebase ID token | What a `user_code` is asking for (client + scopes), shown before approval. |
| `/mcp/connect/tokens` | GET | Firebase ID token | The user's connected agents (never returns a raw token). |
| `/mcp/connect/tokens/revoke` | POST | Firebase ID token | Revoke one connected agent by `token_id`. |
| `/mcp/.well-known/oauth-authorization-server` | GET | none | AS metadata (RFC 8414). |
| `/mcp/.well-known/oauth-protected-resource` | GET | none | Protected-resource metadata (RFC 9728). |

Tokens are **per-user, revocable, and expiring** (`mcp_token_ttl_days`, default
30). Firestore: `mcp_device_codes/{device_code}` (pending → approved/denied →
redeemed, 10-min TTL) and `mcp_tokens/{sha256}` (uid, client_id, scopes,
created/expires, revoked, last_used). Both are Admin-SDK-only; the default-deny
`firestore.rules` already blocks any client read.

### Scopes

`profile:read`, `profile:write`, `matches:read`, `dm:read`, `dm:send`,
`persona:read`. The device request may ask for a subset; the user may narrow
further at approval (never widen). Every tool enforces the specific scope it
needs, server-side.

## Tools (contracts)

Every tool resolves the authenticated uid from the request's Bearer token, checks
its scope, runs the 18+ gate (`age_gate.enforce`), meters the call, and scopes
all data to that uid. The `other_uid`-taking tools derive Firestore paths from
the **caller's own uid** (via `pair_key.sorted_pair_key`), so a cross-user read
is structurally impossible.

| Tool | Scope | Input | Returns | Gates / notes |
|---|---|---|---|---|
| `get_profile` | `profile:read` | — | `{profile:{name,birthdate,gender,interested_in,location,phone,paused,photo_count}, story:[{title,body,visibility,user_edited}]}` | Own profile only. |
| `update_profile` | `profile:write` | `fields:{…}` | `{updated:{<field>:<result>}}` | Structured fields (`name/gender/interested_in/location/phone/birthdate`) go through the shared `set_profile_field` skill — **birthdate under 18 is refused**. `public_text`/`bio`/`story` go through `profile_manual.save_text` — **fail-closed moderation + no-PII (email/phone rejected)**. Text is client-composed; Ayma never writes it. |
| `list_matches` | `matches:read` | — | `[{match_id,other_uid,name,photo,score,structured_score,status,your_explanation,shared,tensions}]` | Only the caller's matches. **Only the caller's own `user_explanation`** is returned; `ai_explanation` never leaves the server. Blocked pairs omitted. |
| `get_match` | `matches:read` | `other_uid` | `{match_id,other_uid,name,score,structured_score,status,dimensions,shared,tensions,missing,your_explanation,score_confidence}` | Reads an **already-scored** match only — never triggers scoring (that would spend an Ayma LLM). `not_found` if unscored. `ai_explanation` never returned. |
| `list_threads` | `dm:read` | — | `[{other_uid,name,last_message_at,unread}]` | Caller's threads; blocked omitted. |
| `get_thread` | `dm:read` | `other_uid`, `limit`(≤100, default 30) | `{other_uid, messages:[{from:'me'|'them',type,body,at,flagged}]}` | Caller's own conversation only (thread id derived from caller uid). Non-text bodies shown as placeholders. |
| `send_message` | `dm:send` | `other_uid`, `text` | `{ok,message_id,thread_id}` | **Stricter than the in-app send** because an autonomous agent is sending it: it **fails closed** — contact info (email/phone) and moderation-flagged content are **refused, not sent**. Blocked recipient → refused. Text is client-composed. |
| `get_persona_context` | `persona:read` | `other_uid` | `{other_uid,name,age,location,photo_count,pages,persona_prompt,note}` | Built only from what the caller can already see (`practice_core.build_persona_context` — the privacy boundary; public-only, private/ai-only spans stripped). The persona **reply is NOT generated server-side** — the client roleplays it. |

**Deliberately NOT exposed:** `dm_assist`, the practice persona-reply generator,
or any other skill that would call an Ayma chat/reasoning LLM. Those would spend
Ayma credits; the client does that reasoning itself.

## Threat model

The connected agent is **untrusted**: the access token proves *which user* asked,
never that a request is *safe*. The client model decides *what* to do; every gate
below is enforced **server-side**, on the Admin-SDK path (which bypasses
`firestore.rules`), so the client cannot bypass it.

| Threat | What a malicious/confused agent attempts | How it's stopped |
|---|---|---|
| **Impersonation / account takeover** | Act as a user it wasn't granted. | No token is issued without an **in-app approval by that signed-in user** (device grant). Tokens are per-user; the uid is read from the server-stored token, never from client input. The device code is single-use and expires in 10 min. |
| **Scraping other users** | Read another user's matches, threads, or private profile. | Every read is scoped to the authenticated uid. Match/DM reads filter on `uid in uids` / `participants`; `other_uid` tools derive the Firestore path from the caller's own uid via the sorted pair key, so a path to someone else's private data cannot be formed. `get_persona_context` / profile-of-another go through `public_profile.build`, which returns only viewer-visible, public, non-blocked data. |
| **Leaking Ayma's private reasoning** | Extract the private `ai_explanation` or the other person's half of a match explanation. | Match tools return **only** `user_explanation[caller]`; `ai_explanation` and the other user's explanation are never serialised. (Covered by a test.) |
| **Bypassing the 18+ gate** | Use the social features as a minor, or set an under-18 birthdate. | Every social tool runs `age_gate.enforce` (closes an under-18 account, same as the app). `update_profile` birthdate goes through `set_profile_field`, which refuses an under-18 date. |
| **Bypassing moderation** | Send abusive/harmful DMs, or post abusive profile text. | `send_message` runs `dm_moderation.moderate` and, unlike the fail-open in-app path, **fails closed** — flagged content is refused. `update_profile` public text runs `profile_manual`'s fail-closed moderation. |
| **PII extraction / exfiltration via DMs or profile** | Push a victim to email/phone, or paste contact info into the public profile. | `send_message` and `update_profile` public text run `check_contact_info`, which rejects emails and phone numbers. |
| **Spam / flooding** | Blast messages or hammer the API. | Per-token in-process rate limit (120/min) in the auth wrapper → 429; the route-level `RateLimiter` also caps the whole `/mcp` prefix per client IP. Each send still runs moderation. |
| **Messaging blocked users** | DM someone who blocked the user (or vice-versa). | `dm_ops.post_message` raises on any block between the pair; the tool surfaces it as a `blocked` refusal. Blocked pairs are omitted from `list_threads` / `list_matches`. |
| **Draining Ayma's AI budget** | Trigger expensive generation (match scoring, chat, persona replies) on Ayma's bill. | **No tool calls a chat/reasoning LLM.** `get_match` reads only already-scored matches; persona replies and bio/DM text are the client's job. Only DM moderation (a cents classifier, unbilled to the user) runs. |
| **Token theft / lingering access** | A leaked or stale token keeps working. | Tokens expire (30 days), are revocable instantly (user "Disconnect", or `/mcp/oauth/revoke`), and only the hash is stored so a Firestore dump doesn't yield usable tokens. The validation cache is ≤10 s, so a revoke takes effect within seconds. |
| **Whole-feature exposure risk** | The feature ships before it's ready. | The `mcp_server` flag defaults OFF; the MCP endpoint and token-issuance endpoints answer 503 until the founder flips it. No secret is required to run it, so there's no half-configured state that leaks. |
| **DNS-rebinding / host confusion** | Trick the SDK's transport host check. | Host pinning is intentionally disabled (behind Cloud Run the Host header is an arbitrary service URL); the real access control is the per-user Bearer token, so host confusion grants nothing without a valid token. |

Residual limitations (stated honestly): as with any device grant, a user who is
**socially engineered** into approving an attacker's `user_code` would connect
the attacker's client to their own account — mitigated by the short 10-minute
code TTL, the approval screen showing the requesting client + scopes, and the
explicit "only approve a code you started yourself" warning, but not eliminated.
The 10-second token cache means a revoke/expiry can lag by up to ~10 s. Rate limits are per Cloud Run instance
(in-process), matching the rest of the app (`ratelimit.py`). A connected agent
can do anything the user could do themselves within the granted scopes — the
gates make it no more dangerous than the user's own app, not less.

## Demo / testing

Backend tests: `functions/bootstrap/tests/test_mcp_oauth.py` (device flow, token
lifecycle, revocation, scope narrowing, expiry), `test_mcp_tools.py` (every
gate: scope, 18+ translation, per-user scoping, no `ai_explanation` leak,
fail-closed moderation + no-PII on send, `get_match` never triggers scoring,
cost-free metering), `test_mcp_server.py` (flag-off 503, bearer-auth 401,
per-token 429, the OAuth routes end-to-end, connected-agent list/revoke).

End-to-end script: `scripts/mcp_demo.py` runs the real device flow against a
running server and drives the tools with the official MCP SDK client (what Claude
does):

```bash
# Local API with the flag on:
FLAG_MCP_SERVER=1 uvicorn main:app --port 8080      # in functions/bootstrap
python3 scripts/mcp_demo.py --base-url http://localhost:8080 \
    --id-token "<firebase-id-token-for-a-test-user>"     # auto-approves
# …or omit --id-token and approve the printed code in the Ayma app.
```

Adding it to an MCP client (e.g. Claude) as a connector: point the client at
`https://<ayma-api-host>/mcp`. The client discovers the authorization server via
the protected-resource metadata and runs the device flow; the user approves the
`user_code` in the Ayma app (Profile → Connect an agent).
