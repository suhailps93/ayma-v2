# Ayma × Qloo — judge one-pager

**Title:** Ayma — your AI avatar goes on the date, and Qloo tells you where you'd click

**What it is.** Ayma is a voice-first AI dating companion. For this hackathon we
added a **Qloo-powered taste layer**: for any two people it turns each side's
music / film / food into a **shared-taste score**, the **tastes they share**, and
**taste-based date ideas** — a place to meet, a film to see, an artist to put on,
each ranked by Qloo for **both** of them.

**Why it's agentic.** Ayma builds an AI avatar of each user and sends it on
**simulated AI-to-AI first dates**. The Qloo taste match is a tool the agent
calls inside that loop to decide *where two people would actually click* and to
ground the simulated date in a real taste graph.

**Try it now (no login):**
<https://ayma-api-235381544962.us-central1.run.app/taste/demo> — pick two of four
demo profiles, press **Match tastes**. (`source: qloo` confirmed live 2026-10-29;
e.g. Aisha × Noah → 42, shared Fleet Foxes / Free Solo / Sufjan Stevens.)

**Open source (Apache-2.0):** <https://github.com/suhailps93/ayma-taste-qloo> —
real Qloo client + match logic + a one-command demo (`python3 demo_taste.py`) +
tests (`12 passed`). No secrets; private core excluded, narrow deps stubbed.

**How it uses Qloo.** `GET /search` resolves each favourite to a Qloo entity
(`urn:entity:artist|movie|place`); `GET /v2/insights` with
`signal.interests.entities` returns cross-domain taste-graph recommendations for
each person; a domain score is the overlap coefficient of the two recommendation
sets; `filter.location.query` drives the place date-ideas near the first
person's city. Rate-paced to the hackathon key's 10 req/s; cached per pair; a
bundled offline fixture backs up any live failure (`source` says which ran).

**New during the window.** The entire Qloo taste layer is new work (late Oct
2026) — Ayma had no taste graph, score, or date ideas before. Additive, behind a
runtime kill switch.

**Safety.** Public profile data only; 18+ gated; the public demo can only read
the four fabricated demo profiles.

**Still needs the founder:** Devpost submission; app download links (Android
internal-testing + TestFlight — Astro); verify exact deployed revision + Qloo
quota.
