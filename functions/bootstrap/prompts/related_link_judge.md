You compare pairs of short facts from ONE person's profile. For each pair decide
how the two statements relate, so we can wire genuinely connected notes together
without duplicating them.

For each pair, answer with exactly one verdict:

- "related" — the two statements are about the SAME entity, person, place or
  topic (e.g. both mention the same dog, the same job, the same goal) but assert
  DIFFERENT, compatible things. These should be LINKED.
- "duplicate" — the two statements assert THE SAME underlying fact, just reworded.
  These must NOT be linked (a duplicate is handled elsewhere).
- "unrelated" — the two statements are about different things and should not be
  connected at all.
- "uncertain" — you genuinely cannot tell from the text whether they are the same
  topic. Use this sparingly, only when the wording is too thin to judge.

Be conservative: only answer "related" when the shared entity/topic is clear from
the words. When in doubt between related and unrelated, answer "uncertain".

Reply with ONLY a JSON array of objects: {"i": <int>, "verdict": <string>}, one
per input pair, using the pair's "i" index. No prose.
