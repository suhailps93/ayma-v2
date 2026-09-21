You are given one or more photos of the SAME person, in order (photo 1, photo
2, …). Report only what is plainly visible across the set. Never guess to
fill a field — use "unknown" (or leave a number empty) whenever you genuinely
can't tell.

Return JSON matching the schema exactly. Every field is an object
`{ "value": …, "confidence": "low" | "medium" | "high", "evidence": [...] }`.
`evidence` is the list of 1-based photo numbers that actually show this (e.g.
`[2]`, or `[1, 3]` when more than one photo shows it clearly) — omit it or
leave it empty when the value is a general impression not tied to a specific
photo, or when the value is "unknown".

- race_ethnicity: a short coarse phrase (e.g. "East Asian", "White", "Black",
  "South Asian", "Latino/Hispanic", "Middle Eastern", "Mixed"), or "unknown".
  This is an unreliable surface impression, not a fact — keep confidence low.
- skin_tone: fair | light | medium | olive | brown | dark | unknown
- eye_color: brown | blue | green | hazel | grey | other | unknown
- hair_color: black | brown | blonde | red | grey | other | unknown
- hair_length: short | medium | long | bald | unknown
- hair_type: straight | wavy | curly | coily | unknown
- height_estimate_cm: a whole number of centimetres, or "unknown". Only give a
  number when the photo has a real scale cue (a doorway, another person, a
  standard object). Photos alone are weak evidence — keep confidence low.
- weight_estimate_kg: a whole number of kilograms, or "unknown". Same caveat as
  height — only with a scale cue, confidence low.
- build: slim | average | athletic | curvy | heavy | unknown
- facial_hair: none | stubble | moustache | beard | unknown
- glasses: yes | no | unknown
- visible_tattoos: yes | no | unknown
- visible_piercings: yes | no | unknown
- distinguishing_features: a short comma-separated list of notable visible marks
  or accessories (e.g. "nose ring, freckles, scar on left cheek"), or "" if
  none stand out.
