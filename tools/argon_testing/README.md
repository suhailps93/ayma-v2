# Argon — Gemini Computer-Use emulator-testing harness

**Dev tool only. Not shipped in the Ayma app.** Lives under `tools/` and is
never imported by `functions/` or `ayma_flutter/`.

Argon drives a real Android emulator (or any ADB-connected device) with
Gemini's **Computer Use** model ("Argon"): it screenshots the screen, asks the
model for the next UI action, executes that action over ADB, and repeats until
the scenario's success condition is met or a step cap is hit. Every run is
recorded as a Markdown report plus an annotated **GIF** that literally shows
where each tap landed.

```
screenshot (adb exec-out screencap)
      ↓
Gemini Computer Use model  ──returns──▶  action (click/type/scroll/key, normalized 0-1000 coords)
      ↓                                        ↓
report + GIF frame  ◀──────────────  ADB input (adb -s <serial> shell input …)
      ↑                                        ↓
      └──────────── next screenshot ◀──────────┘
```

## Credential status (read this first)

The harness reads the Gemini credential **only** from Google Secret Manager at
runtime:

```
gcloud secrets versions access latest --secret=GEMINI_ARGON_API_KEY --project=ayma-ai
```

As of **2026-10-28**, the value in that secret is an `AQ.`-prefixed,
API-key-style credential (the newer Google API-key format that is *bound to a
service account*, not a legacy `AIza…` key, and not a usable OAuth2 access
token — `tokeninfo` rejects it). Against the Gemini Developer API
(`generativelanguage.googleapis.com`) it is **recognised as an API key but
fails to authenticate** on every endpoint with:

> 401 UNAUTHENTICATED — "The bound service account is deleted or disabled. The
> service account bound to the API key must be active." (`ACCOUNT_STATE_INVALID`)

**So Computer Use cannot be exercised with the current secret value.** The
harness is complete and verified up to the model boundary (device capture, ADB
action execution, and the GIF/report pipeline all run against the live
emulator); only the model call 401s.

**To make it run live, put a working credential in the same secret:** a Gemini
Developer API key whose bound service account / project is **active** and has
**Computer Use preview access** to `gemini-2.5-computer-use-preview-10-2025`
(request access at https://ai.google.dev / AI Studio). Then:

```
gcloud secrets versions add GEMINI_ARGON_API_KEY --project=ayma-ai --data-file=<keyfile>
```

No other code change is needed — the model id and environment live in
`config.py`.

## Prerequisites

- **ADB** (Android platform-tools) on `PATH`, with at least one device/emulator
  in `adb devices` (e.g. `emulator-5554`).
- **gcloud CLI** authenticated with ADC (Application Default Credentials) that
  can read the secret(s) in project `ayma-ai`.
- **Python 3.10+** and the tool's deps:
  ```
  pip install -r tools/argon_testing/requirements.txt
  ```
  (`google-genai`, `imageio`, `Pillow`, `PyYAML`.)

## Running a scenario

```
cd tools/argon_testing
python run.py --list                      # list scenarios
python run.py --scenario open_models      # run against the first connected device
python run.py --scenario login --device emulator-5554 --max-steps 20
python run.py --scenario login --no-safety-ack   # halt on Computer-Use safety gates
```

Exit code is `0` on PASS, `1` on FAIL. The report path and GIF path are printed
at the end.

## Scenarios

Scenarios are plain data in `scenarios/*.yaml`:

```yaml
name: open_models
description: >
  Open Ayma's AI-model selection screen.
goal: >
  From the main screen, open the screen where the AI model can be chosen …
success_condition: >
  A screen listing selectable AI models is visible.
credentials:            # optional
  test_email: test.alex@ayma-ai.web.app
  test_password: FROM_SECRET_MANAGER   # never a literal secret in the file
```

Starter scenarios:

| scenario | what it does |
|---|---|
| `login` | Email sign-in with the seeded test account `test.alex@ayma-ai.web.app` |
| `open_models` | Opens Ayma's models / brain / voice selection screen |
| `appearance_report` | Opens the appearance analysis report |

`goal` and `success_condition` support `{placeholder}` substitution from the
`credentials:` block. Any value set to `FROM_SECRET_MANAGER` is pulled from
Secret Manager at runtime; a `*password*` key with no matching secret falls back
to a non-stored interactive prompt.

### Adding a scenario

1. Drop a new `scenarios/<name>.yaml` with `name`, `description`, `goal`,
   `success_condition` (and optional `credentials`).
2. Run `python run.py --scenario <name>`.

That's it — scenarios are discovered by filename; no code change needed.

## Credentials / secrets model

- **Gemini key:** Secret Manager only (`GEMINI_ARGON_API_KEY`, project
  `ayma-ai`), read at runtime, never written to disk, a log, a report, or a
  committed file. Reports scrub any typed password before writing.
- **Test-account password:** Secret Manager (`AYMA_TEST_ALEX_PASSWORD`) if
  present, otherwise an interactive prompt. **The seeded test-account password
  is not currently in Secret Manager** — to run `login` unattended, add it:
  ```
  printf '%s' '<password>' | gcloud secrets create AYMA_TEST_ALEX_PASSWORD \
    --project=ayma-ai --data-file=-
  # or, if the secret exists:
  printf '%s' '<password>' | gcloud secrets versions add AYMA_TEST_ALEX_PASSWORD \
    --project=ayma-ai --data-file=-
  ```
- `.gitignore` in this directory blocks `.env*`, `*.key`, local key caches, and
  generated run artifacts.

## Multiple device configs

The same scenario runs against any connected device by serial:

```
python run.py --scenario open_models --device emulator-5554       # phone AVD
python run.py --scenario open_models --device emulator-5556       # Fold AVD
python run.py --scenario open_models --device <remote-adb-serial> # adb connect <ip:port> first
```

To test across form factors, boot each AVD (or `adb connect` a remote device)
so it appears in `adb devices`, then invoke `run.py` once per serial. The
report header records each device's model, AVD name, Android version, and
resolution, so phone / Fold / small-screen runs are distinguishable.

## Output

Per run, written to `reports/`:

- `reports/<scenario>-<UTC-timestamp>.md` — scenario, device/AVD config, every
  step (intended action + device tap coords + a thumbnail), the embedded GIF,
  and PASS/FAIL vs the success condition.
- `reports/<scenario>-<UTC-timestamp>.gif` — one annotated frame per step (red
  marker at the tap point + action caption), so the GIF shows the clicks.
- `reports/<scenario>-<UTC-timestamp>_frames/` — the per-step thumbnails.

`reports/` is tracked (via `.gitkeep`) but generated `.md`/`.gif`/`_frames/`
are **gitignored** by default. To keep a sample run in git, force-add it:
`git add -f reports/<name>.md reports/<name>.gif reports/<name>_frames/`.

## Configuration

Everything tunable — the Computer Use model id, the mobile environment, step
cap, settle time, GIF sizing, secret names — lives in **`config.py`** and
nowhere else.

## Layout

```
tools/argon_testing/
├── README.md
├── requirements.txt
├── config.py              # single source of model id + all defaults
├── run.py                 # CLI entry point
├── argon/
│   ├── credentials.py     # Secret-Manager reads (runtime only)
│   ├── device.py          # ADB screenshot + input wrapper
│   ├── loop.py            # the Computer-Use control loop + action→ADB mapping
│   └── report.py          # Markdown + annotated-GIF writer
├── prompts/
│   └── task_system_prompt.md   # system prompt (loaded, never inline)
├── scenarios/
│   ├── login.yaml
│   ├── open_models.yaml
│   └── appearance_report.yaml
└── reports/               # run outputs (.gitkeep tracked; runs gitignored)
```
