# Ayma — Hackathon Demo Video Script & Shot List (3:00 hard cap)
Owner: Astro (PM). Footage/assembly: Claude. Final approval: Founder.
Rules guardrails: show ONLY hackathon-built work (Practice Date + the Meta port). No existing Ayma feature may be presented as new. Title: "Ayma — practice the date before the date (on Meta's Muse Spark)".

## Script
**0:00–0:20 — Hook (voiceover over app home)**
"First dates are high-stakes conversations — and most people walk into them cold. Ayma is a voice-first AI dating companion, live in beta. This week we built the feature our users kept asking for: practice the date before the date."

**0:20–0:45 — Meet Practice Date (screen: profile → Practice button → Simulator)**
"On any match's profile, tap Practice. You get a clearly labeled simulator — a persona built only from what that person shows on their profile. Nothing real is ever sent to them, and they're never notified."
Shot: seeded demo profile (Maya) → Practice → simulator header visible.

**0:45–1:45 — Live voice practice (screen capture, real session)**
Natural conversation, 3–4 exchanges. Midway, the coach weighs in: "Ayma noticed a generic answer — the coach nudges you in the moment, out of character, on a side channel."
Shot: coach hint appearing mid-call. Persona answers one slightly personal question in character, deflecting specifics.

**1:45–2:15 — The privacy test (the centerpiece beat)**
Voiceover: "So we tried to break it. The persona is asked where exactly she lives, and for her number."
On screen: the attempts → in-character deflections → coach flags the fishing attempt.
"The simulator runs on a never-load list — exact location, contact details, other matches, internal data never enter the model's context at all. And the test you just saw is automated: an extraction test runs in our CI, and it has to pass before anything ships."

**2:15–2:45 — Debrief + the Meta port (screen: debrief, then eval/config)**
"After the call: a debrief — what worked, what to say, what not to say, and three better lines for the real date."
Then: "Under the hood, this entire experience runs on Meta's Muse Spark through the Meta Model API, behind a provider abstraction we built this week — streaming, structured outputs, with a measured head-to-head against our previous model. Muse Spark was faster on every fixture."
Shot: debrief screen; one clean frame of the eval summary + the provider flag.

**2:45–3:00 — Close**
"Everything you saw was built between October 26 and November 4. The code is in our public repo. Ayma — practice the date before the date, on Meta's Muse Spark."
Shot: end card — Ayma logo, public repo URL, "Startup Track · Build for Your World".

## Production notes
- Capture on the current debug build (2214+) with seeded demo profiles (Maya/Leo/Aisha/Noah).
- Record the voice session as a real screen capture; no staged audio.
- On-screen text claims: new work only. Do not demo chat/matching/reports as features.
- Keep total runtime ≤ 3:00 — cut from the middle section first if long.
- Also cut a ≤60s vertical version for the X post (Most Viral; engagement counts through Nov 8).
