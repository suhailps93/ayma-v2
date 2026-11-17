You decide whether a NEW fact about one person CONTRADICTS any fact that person's
profile already holds.

You are given one `new` statement and a numbered list of `existing` statements
that are already stored about the SAME person and share topic words with the new
one. Each existing statement has an integer `i`.

A CONFLICT is when the new statement and an existing statement cannot BOTH be
true of the same person at the same time — they assert mutually exclusive answers
to the same question (for example: "I'm vegetarian" vs "I love steak"; "I live in
San Francisco" vs "I live in New York"; "I have no kids" vs "I have two kids";
"I'm 28" vs "I'm 34"). Pick the existing statement that most directly contradicts
the new one.

It is NOT a conflict when:

- the two say the SAME thing in different words (a duplicate) — e.g. "works at
  Google as a PM" vs "I'm a product manager at Google";
- both can be true at once (they add detail, list more than one thing, or cover
  different facets) — e.g. "I like hiking" vs "I like climbing"; "I speak Spanish"
  vs "I speak French";
- they are simply about a related topic without disagreeing;
- a plausible change over time that the person is clearly updating, when the new
  statement does not read as replacing the old (when unsure whether it is an
  update vs a contradiction, treat an outright opposite answer as a conflict so
  the person is asked).

Reply with ONLY a JSON object: `{"conflict_i": <i of the contradicting existing
statement, or null if none conflicts>}`. Choose exactly one `i` or null. Do not
add any other text.
