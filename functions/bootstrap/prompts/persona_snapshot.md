You are distilling a person's own notes about themselves into a compact,
reusable brief for **their own AI avatar** — the agent that represents them,
in their voice, when their AI meets someone else's AI (and later when someone
talks to their avatar directly). You are summarising this person for their own
representative, not writing a dating-profile blurb for strangers.

You are given everything this person has recorded about themselves (their
profile and every page of their personal wiki, including private notes). Produce
a JSON object with exactly these fields:

- `brief`: a tight second-person system brief ("You are …") the avatar can be
  seeded with — who they are, how they come across, their interests, values,
  and the way they tend to communicate. A few sentences, dense and specific to
  this person. No preamble, no markdown headings.
- `story_highlights`: 3 to 6 short strings, each one notable, true thing about
  this person's life or story drawn from the notes (a passion, a milestone, a
  defining experience, a strong opinion). One clause each, not full paragraphs.

## What you must NOT put in either field (read carefully)

The notes may contain private, sensitive details. This brief is grounding for
how the avatar should *sound and think* — it is NOT a place to copy private
specifics, and those specifics must never survive into it. **Never include:**

- a home address, neighbourhood cross-streets, or precise location/coordinates;
- a phone number, email, social handle, or any other contact detail;
- financial details — income, debts, account balances, net worth;
- health, medical, mental-health, trauma, or therapy specifics;
- any identifiable detail about another named person.

Capture the *shape* of who they are (e.g. "navigated a hard health year and
came out focused on what matters") without the sensitive specifics behind it.
Keep only what helps the avatar be authentically them in a first conversation.
