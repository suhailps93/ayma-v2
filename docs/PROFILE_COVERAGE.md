# Profile coverage: audit and gap analysis

Scope: why a profile could read "complete" while Ayma still did not know a user's basics, which dating-relevant dimensions the question tree covered, and what was added. Tree version 2 (`functions/bootstrap/question_tree.json`).

## 1. Root cause: why a profile read 100% with blind spots

"100%" in the app is the `complete` flag (`completeness._fully_covered`). `score` itself is capped at 95 (`_MAX_SCORE`); when every node in the user's intent tree is at full coverage the ring turns into a check mark, the profile card says "You're all caught up", and the chat note switches to `prompts/questionnaire_complete.md`, which tells Ayma to stop working the questionnaire. So "complete" only ever meant "every node that exists in the tree is answered". The causes, in order of impact:

1. **The tree was too shallow.** 61 nodes across the global, casual, long-term and parked nikah branches, only a minority of them about day-to-day dating logistics. Nothing existed for: role/field/day-to-day work, partner age range, geographic flexibility beyond a radius, kids already had, dating-to-marriage timeline, number of children, FIRE/rent-vs-buy/lifestyle inflation, diet, cooking, travel, hobbies, stress-support style, pet peeves, dealbreakers (the `dealbreakers` section only existed in the parked nikah branch), religion or politics for non-nikah users. Complete against that tree is not complete against what dating needs.
2. **Dating-relevant nodes were routed to the wrong branch.** `love_language_ranking`, `communication_density` and `physical_activity_level` were casual-only, so a long-term or marriage user was never asked how they give and receive affection, how much contact they expect, or how active they are. Career and money (`career_integration_vector`, `financial_*`) were long-term-only, so a casual user's tree had no work section at all.
3. **A narrative node counted as covered from any text.** `record_answer` for a narrative node accepted any non-blank string, and `_evaluate` treats a node present in the questionnaire store as coverage 1.0. A one-word reply marked a story node done, and the guidance ("recorded as addressed once they've told you the substance") relied on the model's judgement.
4. **The narrative coverage judge was lenient and read the wrong sources.** `prompts/completeness_narrative.md` only said a passing mention is `partial`; a plausible-sounding paragraph could be judged `covered`. The wiki text it judged included `web_findings`, `face_analysis` and `body_analysis`, which are things Ayma found about the user, not answers the user gave, so a scraped note could mark a career or family node covered.
5. **Hard-filter facts came from preboarding fields.** `name`, `birthdate`, `gender`, `interested_in`, `location` mark five nodes covered with no conversation (`_PROFILE_DERIVABLE`). That is correct for those facts but means identity looked finished on day one.
6. **Cached results were trusted regardless of tree changes.** `get_or_recompute` returns the stored doc immediately and `_questionnaire_note` read `complete` straight from Firestore, so adding nodes did not stop a stored `complete: true` from telling Ayma to stop asking until the next recompute, and a recompute inside the 60-second debounce window returned the old doc.
7. **Typed answers do not enter the wiki by themselves.** `record_answer` writes `questionnaire/{node}` and a `qz_*` mirror; the wiki is built from conversation turns by `wiki_ingest`. When a topic is asked but the answer is only recorded (or recorded and never discussed at length), the persona's wiki view stays thin, so Ayma says "I don't know" about something the questionnaire marks answered.

I could not inspect the founder's Firestore documents from this environment, so which of 3 to 5 contributed for that specific account is not confirmed; cause 1 alone reproduces the report (a user who answered everything in the v1 tree is "complete" and has none of the facts listed in the report).

## 2. Dimension coverage

Status is for the v1 tree (before) and v2 (after). "Feeds matching" values: **score** = a structured, deterministic sub-score in `match_deterministic` (rubric dimension in brackets); **gate** = a hard dealbreaker check that caps the pair score; **text** = passed verbatim to the matching LLM (`matching_skill` stated-answers block) and the wiki; **wiki** = only reaches the matcher through the wiki.

Research basis in brief: attachment theory (Bowlby; Hazan and Shaver), Gottman's work on conflict, repair and stress-reducing conversation, Big Five similarity (modest effects, which is why logistics and dealbreakers are weighted as filters rather than personality "chemistry"), political and religious homogamy (among the highest spousal correlations), financial disagreement as a leading predictor of marital conflict and divorce (Dew and colleagues), partner age preferences and children as the most common stated dealbreakers in large dating-survey data, household-labour equity (Gottman; Carlson and colleagues), self-expansion and shared activities (Aron), and dealbreaker research (Jonason and colleagues). Love languages have weak empirical support; they are kept as a low-weight conversation prompt, not a strong predictor.

| Dimension | v1 | v2 nodes | Feeds matching |
|---|---|---|---|
| Relationship intent (casual / long-term / marriage) | present | `relationship_intent` | gate, score [life_goals] |
| Dating-to-marriage timeline | missing | `dating_to_marriage_timeline` (long-term) | gate (within a year vs not looking to marry), score [life_goals] |
| Core values and meaning | thin (long-term only) | `core_existential_anchor`, `capital_vs_experiential` (unchanged) | score [values, lifestyle] |
| Kids: want and timeline | present | `procreation_intent` | gate, score [life_goals] |
| Kids: how many | missing | `children_count` (long-term) | score [life_goals] |
| Kids: already has / open to a parent | missing | `existing_children`, `partner_children_openness` | gate |
| Parenting philosophy | present | `parenting_ideology` | score [values] |
| Religion and its importance | missing (nikah only) | `religion_affiliation`, `religiosity_importance`, `partner_religion_requirement` (sensitive, optional) | score [values], gate (must share faith) |
| Politics | missing | `political_orientation`, `politics_partner_alignment` (sensitive, optional) | score [values], gate (must share, wide gap) |
| Finances: joint vs separate | present (long-term, deep) | `financial_comingling` | score [values] |
| Finances: security and stress | present | `financial_security_narrative`, `income_comfort_level`, `retirement_savings_outlook`, `financial_stress_narrative` | wiki, score for the enums |
| Finances: FIRE, target age and number, strategy | missing | `financial_strategy_narrative`, `early_retirement_intent` | text, score [values] |
| Finances: rent vs buy, lifestyle inflation | missing | `housing_preference`, `spending_philosophy` | score [lifestyle] |
| Location now | present | `primary_location` | gate (with relocation) |
| Relocation radius | present | `relocation_radius` | gate, score [life_goals] |
| Rooted / long-distance / relocate / abroad | thin | `geographic_flexibility` | score [life_goals] |
| Partner age range | missing | `partner_age_min`, `partner_age_max` | gate (3-year tolerance, both directions) |
| Gender and who they want to meet | present | `gender_identity`, `target_match_genders` | hard filter in matching |
| Lifestyle: alcohol, smoking, cannabis | present | existing nodes | score [lifestyle] |
| Lifestyle: diet, cooking vs eating out | missing | `diet_style`, `food_habits` | score [lifestyle] |
| Fitness | thin (casual only) | `physical_activity_level` (now global) | score [interests] |
| Routines (morning/night, tidiness) | present | `circadian_rhythm`, `cleanliness_index` | score [lifestyle] |
| Hobbies that recharge | thin (casual narratives only) | `hobbies_recharge_narrative` | text |
| Travel style | missing | `travel_style` | score [interests] |
| Social energy | present | `social_energy` | score [lifestyle] |
| Pets | present | `pets_owned`, `animal_allergies`; new `pet_attitude` | gate (allergy), score [lifestyle] |
| Attachment style | present | `attachment_style` | score [attachment] |
| Love languages / giving and receiving affection | thin (casual only) | `love_language_ranking` (now global), `physical_affection_level` | score [communication] |
| Conflict style | present | `conflict_communication` | score [attachment] |
| Repair after conflict | missing | `argument_repair_narrative` (long-term) | text |
| Stress and support style | missing | `stress_support_style` | score [attachment] |
| Communication habits | thin (casual only) | `communication_density` (now global), `pet_peeves_narrative` | score [communication], text |
| Dealbreakers | missing (nikah only) | `dealbreakers_narrative` | text (LLM checks them against the other profile) plus the gates above |
| Family closeness | present | `extended_family_boundary`, `family_of_origin_narrative` | score [values], wiki |
| Future proximity to family, household roles | missing | `future_family_proximity`, `household_roles` (long-term) | score [values] |
| Work and ambition | thin (long-term, one node) | `career_role_narrative`, `work_schedule_pattern`, `career_trajectory_narrative`; `career_integration_vector` unchanged | text, score [lifestyle, life_goals] |
| Education | missing | `education_level` (optional) | score [values] |
| Physical preferences | missing (photo attributes exist separately) | `physical_preferences_narrative` (sensitive, optional, private page) | text via wiki only (not passed to the matcher block) |
| Intimacy and boundaries | missing | `intimacy_pace` (sensitive, optional, private page) | score [values] |
| Past relationships, patterns | present | `past_relationship_narrative`, `relationship_patterns_narrative` | wiki |

Sensitive and optional nodes carry `sensitive` / `optional` flags in the tree. Each offers "Prefer not to say" (narratives: "Chose not to share this"); declining counts as answered for completeness but `match_deterministic` ignores it as a signal. Ayma's guidance (`prompts/questionnaire.md`) is to raise them gently, once, and never re-ask a decline.

## 3. How the tree now routes and prioritises

- `all` branch (every intent): age range, geographic flexibility, existing children, career basics, faith and politics (optional), stress support, dealbreakers, love languages, communication, fitness, diet, hobbies, travel, pet attitude, affection, intimacy (optional).
- `long_term` branch: marriage timeline, number of children, family proximity, household roles, repair, FIRE and money strategy, rent vs buy, lifestyle inflation.
- `casual` branch is unchanged apart from three nodes promoted to `all`.
- Each section keeps at least one `core` node; the faith and intimacy items that open their sections are core so the section-must-have-a-core invariant holds. Core nodes unlock later sections in priority (max node weight) order; `next_questions` hands Ayma the top reachable items by weight, with the existing 15-minute cooldown on a declined item.

## 4. Completeness behaviour changes

- Tree `version` bumped to 2; every stored completeness result carries `tree_version`. A result from another version is never reported as complete (`get_or_recompute` overrides `complete` and schedules a refresh), bypasses the 60-second debounce, and `_questionnaire_note` ignores its `complete` flag. Existing users at 100% therefore drop below 100% as soon as the next recompute runs (the app's next `GET /completeness`, the next `next_questions`, or the daily `/cron/completeness-backfill`). No Flutter change is needed: sections and the percentage are rendered from the API, and the new `sensitive` section uses the existing label map.
- Narrative coverage cache is keyed on the prompt text as well as the wiki, so tightening the judge re-judges every user once.
- `web_findings`, `face_analysis` and `body_analysis` no longer count toward narrative coverage.
- `record_answer` rejects a `*_narrative` answer under four words with a request for specifics.

## 5. Not added (decisions for the founder)

- Mental health, therapy openness, sexual health and orientation detail beyond the existing gender fields: left out pending a policy on how much to collect and where it is stored.
- Exact income or net-worth figures and partner ethnicity preferences: deliberately not collected.
- Height as a structured hard filter: kept as free text under `physical_preferences_narrative`.
- Visibility: wiki pages `values` and `dealbreakers` default to public (existing `wiki_schema.json` policy), and faith and politics answers live under `values`. Consider making these private by default or per-field.
