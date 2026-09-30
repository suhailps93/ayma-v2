# Sign in with ChatGPT + per-user OpenAI provider

**Status: built, dark (`CHATGPT_SIGNIN_ENABLED=false`), never run against live OpenAI.**
Gemini stays the locked default for everyone. A user who signs in with (or links)
ChatGPT is routed to OpenAI for chat, story/wiki JSON, web research, image
generation and voice. Everyone else is untouched.

## What is and isn't verified

Verified: unit/integration tests with faked OpenAI (`httpx.MockTransport`), a
real RSA-signed ID token through the OIDC callback, the Flutter flow against a
scripted server.

**Not verified (no client ID, no live call was made):**
- The OIDC endpoints/params (from OpenAI's partner docs, not exercised).
- Whether a ChatGPT-plan token is accepted for **Realtime, image generation and
  web search**. Docs only promise Chat Completions + Responses. Each 403/404 falls
  back to Gemini for that call (see Fallback), so the worst case is "no benefit",
  not "broken".
- Plan scopes are unpublished; we request `openid profile email` only.
- Realtime **audio prices** are unpublished, so voice cost is recorded as $0
  (unpriced, never guessed). Token counts are still recorded.
- No client ID exists yet (partner waitlist). `/auth/chatgpt/config` reports
  `enabled:false` until `OPENAI_SIWC_CLIENT_ID` + redirect URI are set.

## Architecture

```
gemini.py  generate_reply_events / research / generate_json / generate_image
   └─ llm_provider.route_for(uid)      # None => unchanged Gemini code
        └─ openai_provider.*           # Responses API, same return contracts
             └─ openai_client.post     # httpx, bearer, 401-refresh, retry
                  └─ llm_provider.access_token -> openai_auth.access_token
agent.py   _select_voice_model(seed)   # OpenAI Realtime, else Gemini Live
```

- `openai_auth.py` — OIDC + PKCE (public client, no secret). Sessions in
  `openai_auth_sessions/{sha256(state)}` (10 min TTL, single use). Identity map
  `openai_identities/{sub}` -> uid. **Tokens live only at
  `users/{uid}/oauth_tokens/openai`** (server-only; the rule denies clients),
  optionally Fernet-sealed via `OPENAI_TOKEN_ENCRYPTION_KEY`. Never sent to a
  client, never in the room seed, never logged.
- `llm_provider.py` — `route_for(uid)` (30 s cache; any failure => Gemini),
  `Route(uid, billing, provider)`.
- `openai_provider.py` — reply (tool loop <= 3 rounds, function tools +
  `web_search`), research (citations from `url_citation`), JSON (`json_object`),
  image (`image_generation` tool). `store:false` on every request.
- Model IDs are config only (`config.py`); see table.

### Sign-in flow (no deep links in the app)

1. App `GET /auth/chatgpt/config`; button shows only if `enabled`.
2. `POST /auth/chatgpt/start` (Bearer => *link* to this account; none => *sign in*)
   returns `{url, state}`; app opens `url` in the system browser.
3. Browser returns to the HTTPS `GET /auth/chatgpt/callback` (the registered
   redirect URI); server verifies state, exchanges the code (PKCE), verifies the
   ID token (JWKS, iss/aud/exp/nonce), stores tokens, shows a generic page.
4. App polls `POST /auth/chatgpt/return {state}` until `done`; for sign-in it
   gets a Firebase custom token (creates the Ayma user on first ChatGPT sign-in;
   the same ChatGPT account maps to the same user afterwards). A ChatGPT account
   already owned by another user cannot be linked.
5. Settings shows Connect/Disconnect (`/auth/chatgpt/status`, `/disconnect`).
   Disconnect drops tokens and returns the user to Gemini; the identity mapping
   is kept. Account deletion archives + removes `openai_identities`.

## Billing semantics

- **plan** (OIDC): usage goes to `token_usage.plan_total`, `plan_features`,
  `plan_list_cost_usd` and per-event rows with `billing:"plan"`. It **never**
  touches credits or real money, and `token_ledger.check` is skipped (OpenAI's
  own weekly cap is the limit).
- **api** (dev only, `OPENAI_AUTH_MODE=api_key`, operator's `OPENAI_API_KEY`):
  metered and credit-gated exactly like Gemini.
- Prices (per 1M tokens, in/cached/out): `gpt-6.1-sol` $2/0.10/10,
  `gpt-6-luna` 0.10/0.01/0.50, `gpt-6-astra` 10/1/50, image models 5/1.25/30;
  web search $0.01/call. Realtime unpriced.

## Fallback and error contract

| OpenAI response | Behaviour |
|---|---|
| 401 | refresh once; still 401 => drop stored connection, use Gemini |
| 403 / 404 | plan lacks this model/endpoint => Gemini for this call |
| 402, or 429 with a limit code | `ProviderLimitReached` (a `TokenCapExceeded`) — **not** rerouted; the user chose their plan |
| 408/409/429/5xx | 2 retries, then error |
| connection missing/revoked | Gemini |

## Voice

`bootstrap` puts a non-secret `llm_provider` hint in the room seed. The worker
re-resolves the route server-side, fetches the token itself, and builds the
OpenAI Realtime model (`livekit-plugins-openai`); any failure falls back to
Gemini Live. Realtime-only: a STT+LLM+TTS pipeline was **not** implemented
(needs VAD; unverified).

## Config

| Env | Default | Notes |
|---|---|---|
| `CHATGPT_SIGNIN_ENABLED` | `false` | master switch |
| `OPENAI_AUTH_MODE` | `oidc` | `api_key` = dev only |
| `OPENAI_SIWC_CLIENT_ID` / `_REDIRECT_URI` | empty | required to go live |
| `OPENAI_SIWC_ISSUER`/`_AUTHORIZE_URL`/`_TOKEN_URL`/`_JWKS_URL`/`_SCOPES` | auth.openai.com defaults | |
| `OPENAI_BASE_URL` | `https://api.openai.com/v1` | |
| `OPENAI_MODEL` | `gpt-6.1-sol` | text/JSON/research |
| `OPENAI_REASONING_EFFORT` | `low` | |
| `OPENAI_IMAGE_MODEL` | `gpt-image-2.5-sunburst` | |
| `OPENAI_REALTIME_MODEL` / `_VOICE` | `gpt-realtime-2.1` / `marin` | |
| `OPENAI_WEB_SEARCH` | `true` | |
| `OPENAI_TOKEN_ENCRYPTION_KEY` | empty | Fernet key (Secret Manager) |
| `OPENAI_API_KEY` | — | dev `api_key` mode only, Secret Manager |
| `RATE_CHATGPT_AUTH` | `60/minute` | |

## Rollout

1. Get partner access; register the HTTPS redirect
   `https://<api>/auth/chatgpt/callback` exactly.
2. Set client ID + redirect + `OPENAI_TOKEN_ENCRYPTION_KEY` (Secret Manager).
3. Deploy backend **and the voice worker** (`deploy-agent.sh --release`) — the
   worker needs the new `livekit-plugins-openai` dependency.
4. Flip `CHATGPT_SIGNIN_ENABLED=true` for a test account; verify each path
   (chat, story, search, image, voice) and record which plan-token calls 403.
5. Only then ship the app build; the button is hidden until the flag is on.

## Known limitations

- Plan-cap exhaustion shows the existing credits-style message (imprecise).
- If OpenAI becomes unavailable *after* tools ran in a reply, the Gemini
  fallback re-runs those tools.
- Gemini-only for now: `gemini_batch`, `media_embed` (embeddings),
  `voice_preview` (TTS previews), `warmup`.
- The Realtime plugin fixes the API key at construction, so a plan token can
  expire mid-call (the next call is fine).
- Plan events appear as $0 rows in the Credits "Real money" view.
