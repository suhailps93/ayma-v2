# Referral → Equity Program (Ambassador Plan)

Founder intent (2026-09-29): make Ayma go viral by letting the first users earn
real upside — the more **active** users they refer, the more stock options they
get. Pilot with a few San Jose State University students; their referrals must
be in San Jose / the Bay Area to count. There must be a referral link (shipping
now) and an agreement governing how this works.

## 1. The one legal thing to get right first

Stock options **cannot simply be handed out for referrals**. Options must be
granted under an equity incentive plan to eligible people (employees,
directors, *consultants/advisors performing bona fide services*), approved by
the board, priced at 409A fair market value, within securities exemptions
(Rule 701). Paying equity per-referral to random users would look like paying
for securities distribution / unregistered broker activity.

**The clean structure — Campus Ambassador Agreement:**
- Each ambassador signs a lightweight **advisor/ambassador consulting
  agreement** (services: campus promotion, feedback, referrals). That makes
  them Rule-701-eligible service providers.
- Compensation: an **option grant with milestone vesting** — e.g. options vest
  in tranches as verified-active referral counts hit tiers. Board approves the
  grants; strike = current 409A. Points → tranches, never "1 referral = N
  shares" in marketing copy.
- Cap the pilot pool: e.g. **1% of fully diluted** reserved for the ambassador
  program, 10–20 ambassadors max. A single lawyer pass (~1 hr) over the
  agreement template before anyone signs. NOT legal advice — have counsel
  confirm Rule 701 fit and the consulting characterization.
- In-app there is **no equity language** shown to referred users; only
  ambassadors see their dashboard/agreement.

## 2. Program mechanics

- **Ambassador**: invited manually by the founder (flag on `users/{uid}`:
  `ambassador: true`, `ambassador_agreement_accepted_at`). Not self-serve.
- **Qualified referral** = referred user who (a) signed up with the
  ambassador's code/link (attribution already shipping), (b) has profile
  location resolving to the allowed geo set (start: San Jose / Santa Clara /
  Bay Area counties list), and (c) becomes **active**: completed onboarding
  + ≥N meaningful Ayma conversations (e.g. 3 sessions on 3 distinct days) +
  still active at day 30. Activity is measured server-side from data we
  already have (sessions, wiki growth) — never self-reported.
- **Tiers (example, tune later)**: 10 qualified → tranche 1; 25 → tranche 2;
  50 → tranche 3; 100 → tranche 4 (largest). Leaderboard among ambassadors.
- **Anti-fraud**: device/phone-number uniqueness on referees, geo check at
  activity time not just signup, no self-referrals (already enforced),
  clustering review in the admin console before any tranche is certified,
  founder manually certifies tranches (small numbers — human review scales
  fine at pilot size).

## 3. SJSU pilot

1. Recruit 5–10 SJSU students (founder's network / campus clubs).
2. Each signs the ambassador agreement (DocuSign or in-app click-through of
   the signed PDF; store acceptance timestamp + version).
3. They get their referral link (feature shipping now) + a private tier sheet.
4. Weekly: founder reviews qualified-referral dashboard, certifies counts.
5. At tranche milestones: board consent + option grant paperwork (Carta or
   equivalent).

## 4. Build plan (incremental, mostly already underway)

| Phase | What | Status |
|---|---|---|
| 0 | Referral codes/links + signup attribution + invite/share UI | **in flight now** |
| 1 | `ambassador` flag + qualified-referral computation job (geo + activity rules) + admin dashboard section (per-ambassador counts, pending/qualified/certified) | next |
| 2 | Ambassador view in-app: their link, live qualified count, tier progress, agreement acceptance record | after 1 |
| 3 | Agreement click-through flow (render PDF, record acceptance) | with 2 |
| 4 | Tier certification tooling (founder marks a tranche certified; export for counsel/Carta) | when first ambassador nears tier 1 |

## 5. Open decisions for the founder

- Pool size + tier share counts (with counsel/409A in hand).
- "Active" thresholds (proposal above: onboarded + 3 days of sessions + alive
  at day 30).
- Allowed geo list v1 (proposal: Santa Clara County + SF + Alameda + San
  Mateo).
- Whether non-ambassador users get any lightweight referral reward (e.g.
  credits) — separate from the equity program, avoids equity-for-everyone
  creep.
