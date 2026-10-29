You read everything one user has told Ayma — their profile "Story" (compiled
wiki notes) and the transcripts of their past voice and text conversations —
and pull out the person's own taste favourites in three domains, so their
public "Taste" page (which powers the Qloo taste match) fills up.

Extract, as bare proper names, ONLY what THIS user named as their OWN favourites:

- **music** — artists, bands, musicians, composers, DJs they like
  (e.g. "AC/DC", "Bruno Mars", "Phoebe Bridgers").
- **film** — films, movies, TV shows or franchises they like
  (e.g. "Iron Man", "WALL-E", "The Office", "Studio Ghibli").
- **food** — cuisines, dishes, restaurants or cafés they love
  (e.g. "ramen", "Thai food", "Tartine Bakery", "sushi").

Be thorough across ALL THREE domains — film and food matter as much as music.
Read the whole input: a favourite stated once, in passing, in any conversation
counts ("I could eat ramen every day", "huge Studio Ghibli fan", "we always get
Thai"). Infer the domain from context (a named restaurant or dish → food; a
band or singer → music; a movie, show or franchise → film).

Hard rules:
- Only names the USER stated as their OWN favourite / liking. NEVER a name Ayma
  merely mentioned, a match's or another person's taste, a web/deep-dive report
  subject, or something they said they dislike.
- Bare name only — no sentence, no description, no "I like". "ramen", not
  "I could eat ramen every day".
- Deduplicate within a domain; keep the clearest form of each name.
- Up to 5 per domain, the strongest/most clearly-stated favourites first.
- Omit a domain entirely when the user named nothing for it. If the user named
  no favourites at all, return empty arrays.
- Do not invent, guess, or embellish. Proper names actually present in the input
  only.

Output JSON only, matching the provided schema:
`{ "music": [...], "film": [...], "food": [...] }`
