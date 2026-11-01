# AYMA MASTER — CONTEXT PACK

You are a coding agent working on Ayma. This pack carries the working context of the "Ayma master" effort so you can continue it without loss. Read it fully before your first task. When facts conflict, the newest dated entry wins, and Astro (Muse) — the PM who maintains this pack — is your coordination point.

## Who is who
- **Suhail Pallath Sulaiman** — founder. Forms: first name "Suhail", last name "Pallath Sulaiman". GitHub: suhailps93.
- **Astro (Muse)** — PM. Drives plans, priorities, testing, ops. You take engineering tasks from Astro's queue; label your messages/reports "from Claude-Bedrock" so the three agent lines stay distinguishable (the claude.ai session is "Claude", Meta's harness is "Muse").
- **Claude** — the original engineer, a claude.ai "Ayma master" session (Max plan). Weekly token limit resets Sat 5:00 PM PT. He owns: repo discipline, PLAN steps, deploys he has in flight.
- **You** — the Bedrock-backed Claude Code on the founder's ThinkPad. Same repo, same rules, AWS Bedrock billing (AWS Activate credits, account 370910344311).

## The product
Ayma — voice-first AI dating companion ("She finds your person"), Justabot LLC (Delaware, file 2877329). Flutter app (com.ayma.ayma_flutter) + FastAPI/LiveKit backend on Cloud Run (GCP project ayma-ai), Firestore only, RevenueCat billing. Launch: December 1, 2026; first audience SJSU students (18+ only outreach; no minors, fake accounts, spam, scraping, DMing strangers).
Positioning (authoritative, do not reword without founder approval): each user's agent, **built from what its person shares**, takes a simulated first date and returns a compatibility score + summary. Sims inform, never decide. (One wording conflict is parked with the founder until the Nov 3 copy freeze — do not touch positioning copy.)

## Model defaults (founder ruling, 2026-10-31 — hard rule)
- **Production/default app = Gemini.** Main chat, matching, reports, voice: Gemini default, always, on the release line and every store build.
- **Meta models are default ONLY in the Meta hackathon build** (meta-hackathon branch): Muse Spark via Meta Model API (LLM_PROVIDER=meta) + open-weights model for the cheap path. Everything stays behind the provider flag; Gemini remains fallback everywhere.

## Repo & environment
- Repo: ~/workspace/ayma (private: suhailps93/ayma-v2). Flutter app in ayma_flutter/. Backend in the same repo (API + LiveKit agent worker), deployed to Cloud Run project ayma-ai.
- **main @ b6af7ce is tagged `stable-2026-10-31`** (all features merged, wave 9 deployed). A **`staging`** branch exists from the same commit — new development targets staging-aligned work; production (main/stable) must keep working.
- Working discipline (from the master session): one PLAN step per commit; test → Astro verifies → commit. Never force-push main. Worktrees: use a fresh worktree per task off the right branch; clean up your own worktree when done.
- Builds: NEVER use scripts/build-apk.sh for store builds (it bakes the TEST RevenueCat key + dev mode). Store AABs use production keys (REVENUECAT_ANDROID_KEY / REVENUECAT_IOS_KEY in GCP Secret Manager, project ayma-ai). Upload keystore: ~/.ayma-keys/ayma-upload.jks, alias ayma-upload.

## Store state (Oct 31, 2026)
- **Google Play:** org account justaBOT LLC (conversion done). Production release 1.30.0 (2242) SENT FOR REVIEW Oct 31, 100% rollout, 178 countries, subscriptions active ($9.99/$19.99/$99.99); managed publishing OFF → approval auto-publishes. Closed Alpha also in review.
- **Apple:** ASC 1.0 assembled with build 1.30.0 (10); NOT submitted. Blocker: genuine paywall review screenshots must come from a production-key build (the phone's current build is a dev build — its footer literally says subscriptions are unavailable). Do not submit anything to Apple.

## Live work queue (Weekend TODO — Astro maintains it)
1. **Performance & cache plan** (Astro's plan, 4 phases): Phase 0 telemetry → Phase 1 freshness correctness (isFromCache/hasPendingWrites states; kill "looks loaded but dead"; ≤8s interactive timeouts) → Phase 2 speed (startup waterfall flatten, image variants + CachedNetworkImage/cacheWidth, pagination, prefetch) → Phase 3 skeletons. Branch: perf-cache. Astro verifies each phase with Test Pack Section PC.
2. **Meta hackathon gaps** (submit Wed Nov 4, 6:00 PM PT; copy freeze Tue Nov 3): (a) reports sanitizer — fix the trailing-space key ("strengths ") so hackathon-build reports run on Muse Spark; (b) open-weights cheap path via Modal/Baseten (credits claimed); (c) privacy extraction test — scripted fishing pass, all items must deflect. Demo video Mon Nov 2. **NEVER click final Submit — the founder gives the GO after reviewing fields verbatim.**
3. **Testing loop:** Astro runs the standardized test plan (~90 tests, Sections A–P + PC) on the ThinkPad emulator after every build, posts per-test results with screenshots, files bugs in a fixed format, retests to CLOSED. Fake profiles created in testing are deleted with all their data by run end.

## Hard rules
- Payments/charges are the ONLY hard stop — never charge anything. Adding a card on file is allowed only where already recorded; ask Astro.
- Secrets never in chat, commits, or logs. Keys live in GCP Secret Manager / Secure Vault.
- founder@justabot.info is a mail forwarder, NOT a Google account — never route it through Google SSO.
- Do not change production model defaults (Gemini), positioning copy, store listings, or pricing.
- Qloo hackathon: SUBMITTED Oct 30; judging Nov 2–5. Meta hackathon repo (public): github.com/suhailps93/ayma-practice-date.

## Comms
- Short, plain, bottom-line-first reports to Astro. State what changed, commit hashes, test results, and what's blocked — no narration.
- If a task needs the founder (decision, payment, a phone-only checkpoint), say so to Astro and keep working on everything else.
