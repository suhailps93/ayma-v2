# Demo accounts (hackathon / judges)

Three complete, lived-in demo profiles anyone can log into to try Ayma. They are
built and kept in sync by an idempotent seed script
(`scripts/seed_demo_accounts.py`) that writes real data through the app's own
code paths. Share this page with judges.

## Logins

| Login | Password | Who they are |
|-------|----------|--------------|
| `test1@gmail.com` | `Test123` | **Daniel Reyes**, 29, man seeking women — UX designer, weekend potter, folk-show regular (San Jose). |
| `test2@gmail.com` | `Test123` | **Sofia Marino**, 27, woman seeking men — ceramic artist & art teacher (San Jose). **Strong match for Daniel.** |
| `test3@gmail.com` | `Test123` | **Priya Nair**, 30, woman seeking men — investment analyst, jazz & sci-fi, firmly childfree (San Jose). **Deliberate poor match for Daniel.** |

The password is the same for all three and is intentionally published here —
these are throwaway demo logins, not real accounts. No other credential appears
in this repo.

## The intended story (good match vs bad match)

Ayma is a taste-aware dating app. The three accounts are built so a judge can
see the contrast immediately:

- **Daniel (test1) × Sofia (test2) → strong match.** Near-identical values and
  life goals (both want a long-term relationship and kids soon, both secure,
  both creative homebodies) and a big **Qloo taste overlap** (shared folk/indie
  music, quiet romantic films, artisan bakeries). The match report shows a high
  score and a rich taste card with date ideas.
- **Daniel (test1) × Priya (test3) → poor match.** Priya is firmly childfree
  (a hard incompatibility with Daniel, who wants kids) and her taste diverges
  (jazz, sci-fi, fine dining). The match score is capped low and the taste card
  shows little overlap.

Measured scores (see the live numbers printed by
`scripts/verify_demo_accounts.py`):
- **Match** (`matching_skill.score_pair`, 0–1): Daniel×Sofia ≈ **0.99**,
  Daniel×Priya ≈ **0.25**.
- **Taste** (live Qloo, `taste_match`, 0–100, all 10 domains): Daniel×Sofia =
  **68 "Good taste overlap"** (filled per-domain bars + shared entities Bon Iver,
  Fleet Foxes, Lost in Translation, Tartine Bakery, Fleabag, The Bear);
  Daniel×Priya = **25 "Some taste overlap"**. (Offline, the bundled Qloo fixture
  has only a few entities per newer domain so it over-scores the poor pair; the
  deployed app uses live Qloo, where the split is as shown.)

## What each profile has

Everything a finished real user has, so every screen looks lived-in:

- Full **profile** (name, birthdate/age, gender, orientation, location, distance
  & age preferences) with a **high completeness** score.
- **Photos** — AI-generated (Google Gemini image model on Vertex, project
  `ayma-ai`): a consistent face shot + full-body + a candid, all fully clothed
  and modest, run through the real photo pipeline (moderation, attributes,
  grid) and an **Appearance report**.
- A full **Story** (`wiki_pages`) — identity, career, interests, values,
  lifestyle, relationships, family, social circle, dealbreakers.
- A multi-turn **Ayma conversation** (chat + raw turns) so "My story / Ayma's
  notes" reads naturally.
- Complete **taste** (music / film / food) for the public Taste page and the
  Qloo match card.
- An **AI avatar** (persona snapshot) you can chat with.
- Real **DMs**: Daniel↔Sofia (warm) and Daniel↔Priya (polite but off).
- They are **discoverable in Explore** for each other and for the founder's
  account (located in San Jose, within the founder's saved age range).

## Two scoped mechanisms behind these accounts

Both are limited to exactly these accounts and change nothing globally
(see `docs/FEATURE_FLAGS.md` and `docs/ARCHITECTURE.md`):

1. **Email-verification bypass.** Ayma has no hard email-verification wall — you
   can sign in and use the app without verifying email. The one privilege that
   does read `email_verified` is the free start-grant contact check
   (`start_grant.contact_verified`). The three demo emails
   (`CONFIG.test_bypass_emails`) clear that check even though their email is
   unverified; **every other account is still gated.**
2. **All feature flags on.** The three demo uids (`CONFIG.all_flags_on_uids`)
   resolve every boolean feature flag ON via a per-user override in the flag
   reader (`feature_flags.resolve(name, uid=…)`), **without flipping any global
   flag**.

## Rebuilding / resetting

Run from the repo root with Application Default Credentials for `ayma-ai`
(`gcloud auth application-default login`):

```bash
# create / update everything (idempotent — safe to re-run)
python3 scripts/seed_demo_accounts.py

# wipe the three accounts' data + auth users, then rebuild from scratch
python3 scripts/seed_demo_accounts.py --reset

# verify every requirement and print evidence
python3 scripts/verify_demo_accounts.py
```

Flags: `--no-images` skips (slow) image generation; `--no-llm` skips the
Gemini-generated story / conversation / DM / avatar content. Persona facts live
in `scripts/demo_seed/personas.json`; the generation prompts live in
`prompts/demo_seed/*.md`.

The seed uses only Application Default Credentials and reads no secrets. When run
locally it forces the Vertex-Gemini transport for its own process (the deployed
Meta/Inference routing needs secrets the script doesn't carry); this changes no
committed default and no deployed configuration.
