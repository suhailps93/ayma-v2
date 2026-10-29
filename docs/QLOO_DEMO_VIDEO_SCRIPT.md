# Ayma × Qloo — demo video script (target 2:30, hard cap 3:00)

Guardrail: show **only** the Qloo-built taste layer as "new." The rest of Ayma
(auth, matching, voice) is pre-existing and must not be presented as new work.
Every taste result on screen must read `powered by Qloo` / `source: qloo`.

| Time | Visual | Voiceover |
|---|---|---|
| **0:00–0:15** Hook | App home / two profile cards side by side. | "Dating apps match you on photos and checkboxes — then the first date is still a cold guess. Ayma does it differently: it builds an AI avatar of you, sends it on a simulated first date, and uses **Qloo** to tell you where you'd actually click." |
| **0:15–0:35** The taste signal | Questionnaire: Ayma asks "What music, films, and food do you love?" → answers fill a public **Taste** page (`Music: … Film: … Food: …`). | "You never fill out a taste form. Ayma just asks — in conversation — what you're into. Your answers become a public Taste page: a few artists, films, and places." |
| **0:35–1:05** Qloo under the hood | Simple animated diagram: names → `GET /search` → Qloo entities → `GET /v2/insights` (both people's entities) → overlap + places. | "Here's the Qloo part. Each name resolves to a Qloo taste-graph entity. Then Qloo's Insights API, driven by *all* of your tastes at once, finds what two people's taste graphs have in common — across music, film, and food together — and recommends places, films, and artists for **both** of you." |
| **1:05–1:45** The judge demo (live) | Screen-record **/taste/demo**: pick **Aisha** and **Noah** → **Match tastes** → the card renders: score 42, shared *Fleet Foxes / Free Solo / Sufjan Stevens*, date ideas *Berkeley Rose Garden, Marriage Story, Sufjan Stevens*. Point at the "powered by Qloo" label. | "This is live, no login — judges can open it right now. Pick two people, press match. Qloo gives us a shared-taste score, the exact tastes they share, and real date ideas: a place to meet, a film to see, an artist to put on — each ranked by Qloo for both of them." |
| **1:45–2:15** In the product | App: open a match report → scroll to the **"Taste match · powered by Qloo"** card under the compatibility score; then the AI date-simulation result showing the same card. | "In the app it lands where it matters — on the match report, and on the result of an AI-run simulated date. Your agent took the first date; Qloo tells you where the real one should be." |
| **2:15–2:30** Close | Repo page (github.com/suhailps93/ayma-taste-qloo, Apache-2.0) + the one-command demo in a terminal: `python3 demo_taste.py`. | "All of it — the Qloo client, the match logic, a one-command demo — is open source, Apache-2.0. Ayma, powered by Qloo." |

**Shot list / assets needed**
- Screen recording of `/taste/demo` with a real `source: qloo` result (Aisha × Noah is a good one — score 42, rich shared list).
- App screen recording: match report Taste card + date-sim result Taste card (needs a build with the card visible — `TODO(verify)` it's in the installed APK; see memory rule "only test fully-shipped-on-phone").
- The Qloo flow diagram (search → insights → overlap).
- Repo + terminal `demo_taste.py` run (already works on the fixture; use live key for the recording if you want `source: qloo`).
- Keep total ≤ 3:00. Owner: Astro (PM) / founder approval on final cut.
