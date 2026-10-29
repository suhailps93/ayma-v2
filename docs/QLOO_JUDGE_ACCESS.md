# Qloo hackathon — judge access notes

Everything a judge needs to test Ayma's Qloo taste match, free and unrestricted
through judging.

## 1. Live demo (no login, no install) — primary

**<https://ayma-api-235381544962.us-central1.run.app/taste/demo>**

Pick two of the four fabricated demo profiles (Maya · SF, Leo · Oakland,
Aisha · Berkeley, Noah · San Jose) and press **Match tastes**.

- JSON directly: `GET /taste/demo/pair?a=maya&b=leo`
  (allowed ids: `maya`, `leo`, `aisha`, `noah`; any other id → 404, so it can
  never read a real user).
- First match per pair is ~6.5–7.5 s (real Qloo Insights calls); cached after.

**Confirmed live 2026-10-29** (all return `source: "qloo"` — the real Qloo API):

```
GET /taste/demo            -> 200 (HTML demo page)
GET /taste/demo/pair?a=maya&b=leo    -> 200  score 25  (music 0,  film 25, dining 50)
GET /taste/demo/pair?a=aisha&b=noah  -> 200  score 42  (music 50, film 25, dining 50)
GET /taste/demo/pair?a=maya&b=aisha  -> 200  score 25  (music 50, film 12, dining 12)
GET /taste/demo/pair?a=leo&b=noah    -> 200  score 25  (music 0,  film 25, dining 50)
```

## 2. Open-source repo (Apache-2.0)

**<https://github.com/suhailps93/ayma-taste-qloo>** — license shows in About.

Run the whole pipeline locally in ~30 s, no key / db / network:

```bash
cd backend
python3 -m pip install -r requirements-test.txt
python3 demo_taste.py        # Music/Film/Food -> Qloo (fixture) -> score + date ideas
python3 -m pytest -q         # 12 passed
```

Set `QLOO_API_KEY` to run `demo_taste.py` against the live Qloo API
(`source: qloo`).

## 3. The app (optional — for the in-product experience)

The Qloo card also appears in the app on the match report ("Taste match · powered
by Qloo") and on the AI date-simulation result. Download options for judges:

- **Android** — internal-testing link: `TODO(verify)` — confirm the Play
  internal-testing link and that the installed APK contains the Taste card
  (per the "only test fully-shipped-on-phone" rule, don't send judges to an
  in-app feature that isn't in the shipped build yet).
- **iOS** — public **TestFlight** link: `TODO(verify)` — Astro is setting this
  up; paste the link here when ready.

The live demo (section 1) and the repo (section 2) fully satisfy the "functional
demo + free testing access" requirement on their own; the app is a bonus.

## 4. Kill switch (operator note, not judge-facing)

If Qloo billing must be stopped: `scripts/flags.py set qloo_enabled=false --yes`
(no redeploy). The demo then returns the no-taste empty state and makes zero Qloo
calls. Leave it **ON** for judging. `TODO(verify)` remaining Qloo quota/credits.
