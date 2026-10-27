# Grok-inspired feature backlog (settings + UX)

Source: 9 Grok app screenshots the founder shared (2026-10-27). Each Grok screen
mapped to an Ayma equivalent, with status. This is a candidate backlog — only the
items the founder picks get built. Fold the chosen ones into PLAN.md / this queue.

Status key: ✅ done · ◐ partial (some of it exists) · ☐ new.

| # | Grok screen | What it does | Ayma equivalent to build | Status |
|---|---|---|---|---|
| 1 | **Widget** ("Ask Grok") | Home-screen widget with quick chat / imagine / voice buttons | Home-screen widget: quick **voice call with Ayma**, quick "new matches", quick open-last-DM | ☐ new |
| 2 | **Haptics** | Master haptics toggle + per-event (button press, "AI is responding") | Haptics settings: master on/off + per-event (taps, voice/agent events, match) | ☐ new |
| 3 | **Appearance** | System / **For You** / Dark / Light + text-size slider with live preview | Ayma has Dark/Light + accent color. ADD: a "For You" adaptive theme + **text-size slider with live preview** | ◐ partial |
| 4 | **Data Controls** | Personalize using X data · Personalize with location · Allow chat-link sharing · Response notifications · Delete all conversations / media / **Delete account** | Data Controls hub: **data-use/personalization opt-in** (ties to the data-for-ads plan — disclose in terms), location-personalization toggle, share-link toggle, **notifications** (date-sim done, new match), destructive: delete all DMs, delete practice/reports, delete account | ◐ partial (account deletion exists via biometric-consent withdraw) |
| 5 | **Shared Conversations** | List of shared links + revoke; "anyone with the link can view" | **Manage shared links** hub: shared reports, shared profile, shared practice-dates — see & **revoke** each | ◐ partial (sharing exists; central management is new) |
| 6 | **Bots** | Vault (creds), auto timezone, Bot Computer, Your plugins | Agent/MCP settings: **connected-agent management** (done via Connect-an-agent/MCP), agent timezone, "your plugins/tools" | ◐ partial (MCP connect shipped) |
| 7 | **Report a Problem** | Category dropdown + describe + attach images + submit | In-app **Report a Problem**: category + description + screenshot attach + submit | ◐ partial (feedback-catcher exists) |
| 8–9 | **Settings (main)** | Grouped sections: Skills, Kids Mode, **NSFW Preferences**, Voice, Bots, Data & Information (Shared Conversations, Data Controls, legal links), Report a Problem, Sign out, version footer | **Settings reorg** into labelled groups with icon + title + subtitle rows; legal links grouped; version footer. **NSFW Preferences** relevant (18+ content prefs). Kids Mode N/A (Ayma is 18+). "Skills" = capability toggles | ◐ reorg |

## Settings reorganization (the structure Grok uses, applied to Ayma)

Grok groups settings under clear section headers with icon+title+subtitle rows and
a version footer. Proposed Ayma grouping:

- **You** — profile, pause matching, AI Avatar opt-out, verification/consent.
- **Appearance** — theme (System/For You/Dark/Light), accent color, **text size (slider + preview)**, **haptics**.
- **Voice** — the voice-engine stack (brain/STT/TTS), language & accent.
- **Agent (BYO)** — Connect an agent (MCP), connected agents, agent timezone, plugins.
- **Content** — NSFW preferences (18+).
- **Data & Information** — Data Controls (personalization/data-use, location, notifications), **Shared links** (view/revoke), legal (Terms, Privacy, Open-Source Licenses), delete-account.
- **Support** — Report a Problem.
- Footer: app version.

## Highest-value picks (recommendation)
1. Settings reorg (makes everything else discoverable) — #8/9.
2. Data Controls hub incl. the data-use opt-in — #4 (also the legal/ads-disclosure home).
3. Report a Problem (#7) — tightens the feedback loop during the hackathon.
4. Text-size slider + haptics (#2/#3) — cheap polish, strong perceived quality.
Widget (#1) and "For You" theme are nice-to-haves for after the hackathon.
