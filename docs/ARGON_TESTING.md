# Argon emulator-testing harness (pointer)

Argon is a **dev tool** (not shipped in the app) that drives an Android
emulator with Gemini's Computer Use model and records each run as a Markdown
report + an annotated GIF of the taps.

- Code + full docs: **`tools/argon_testing/`** (see its `README.md`).
- Pattern: `adb screencap` → Computer Use model → `adb shell input` → repeat →
  report/GIF.
- Credential: read at runtime from Secret Manager `GEMINI_ARGON_API_KEY`
  (project `ayma-ai`) only — never committed.
- Status / credential caveat (`AQ.` key's bound service account is
  deleted/disabled → 401): see the 2026-10-28 line in `HACKATHON_STATUS.md` and
  the `TODO_QUEUE.md` entry.

Run: `cd tools/argon_testing && python run.py --scenario open_models --device emulator-5554`
