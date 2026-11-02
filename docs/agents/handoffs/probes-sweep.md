# Probes sweep: Gemini keys, Cursor CLI, Pixel reachability

From Astro (Muse, PM), assigned 2026-11-02 ~10:50 PT. Branch `muse/probes-sweep`.
Report-only; no app code, no env/service changes. All times PT (UTC in outputs).

## 1. Gemini key probe — 10:45–10:46 PT — NO KEY PASSES (Gemini stays parked)

Ran the `gemini-ayma` wrapper's own probe per key: the exact `probe()` curl from
`~/.local/bin/gemini-ayma` (tiny `generateContent` on `gemini-3.8-flash`,
`maxOutputTokens: 8`, `--max-time 120`), keys fetched from Secret Manager
(project `ayma-ai`) exactly as the wrapper does. Key values never printed.

| Key (secret) | Fetch | HTTP | Detail |
|---|---|---|---|
| primary (`GOOGLE_API_KEY`) | ok | **503** | `UNAVAILABLE`: "This model is currently experiencing high demand…" |
| fallback (`GEMINI_ARGON_API_KEY`) | ok | **503** | same 503 model-capacity message |
| fallback2 (`GEMINI_JUSTABOTHELP_API_KEY`) | ok | **429** | Free-tier daily quota exceeded on `gemini-3.8-flash`; "Please retry in 13h13m56s" (≈08:00 UTC Nov 3 / ≈midnight PT) |

Wrapper's own verdict (`gemini-ayma --help`, 10:45 PT, exit 1), verbatim:

```
gemini-ayma: all profile keys quota-dead or unavailable - waiting for reset (no paid tokens, founder rule)
```

Note: the two 503s are model-capacity errors, not key-quota errors — but the
wrapper treats any non-200 as dead, so no key is picked. Fallback2's 429 names
an ~13h retry. **No key passes — do NOT relaunch Gemini's parked chunk.**

## 2. Cursor CLI probe — 10:46 PT — authenticated, no limit shown, no reset date

`cursor-agent status` (exit 0):

```
✓ Logged in as suhailps@gmail.com
```

`cursor-agent status --format json`: `authenticated`, tokens present,
`suhailps@gmail.com` (userId 158469746). No usage/limit/reset fields exist.

`cursor-agent about`: CLI `2026.10.22-27dcf5f` (up to date), Subscription Tier
**Free**, OS linux x64. `cursor-agent models` lists fine (authenticated API
call succeeds).

Verdict: **CLI READY at auth level** — logged in, up to date, account API
reachable, no limit banner, **no reset date shown anywhere**. Caveat: the CLI
exposes no usage/quota readout, and no live `-p` inference probe was run (it
would spend Free-tier usage and the brief scoped this to the status check), so
agent-quota state is unverified beyond "no limit advertised."

## 3. Pixel reachability — 10:46 PT — UNREACHABLE (fresh evidence, retried)

Fresh file read in this run: `~/workspace/ayma-inbox/.autodeploy/pixel_addr`
→ `10.0.0.203:39857`. Nothing installed; reachability only.

```
$ adb connect 10.0.0.203:39857
failed to connect to '10.0.0.203:39857': No route to host
$ adb devices
List of devices attached
emulator-5554          device product:sdk_gphone64_x86_64 model:sdk_gphone64_x86_64 device:emu64xa transport_id:1
```

Retried after 10s: identical `No route to host`. Only emulator-5554 attached.
Verdict: **Pixel UNREACHABLE** — from this run's file-read + connect, not a
stale port. Staging installs will keep skipping until the phone is back on LAN
(or the addr file rotates to a live endpoint).
