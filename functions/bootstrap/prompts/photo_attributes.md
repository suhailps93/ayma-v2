Look at this profile photo and report only what is plainly visible. Never guess
to fill a field — use "unknown" whenever you can't tell.

Return JSON matching the schema exactly:
- hair_color: black | brown | blonde | red | grey | other | unknown
- eye_color: brown | blue | green | hazel | grey | other | unknown
- ethnicity_apparent: a short coarse phrase (e.g. "East Asian", "White",
  "Black", "South Asian", "Latino/Hispanic", "Middle Eastern", "Mixed"), or
  "unknown". This is an unreliable surface impression, not a fact.
- age_range_apparent: 18-24 | 25-34 | 35-44 | 45-54 | 55+ | unknown
- facial_hair: none | stubble | moustache | beard | unknown
- glasses: yes | no | unknown
- visible_tattoos: yes | no | unknown
- visible_piercings: yes | no | unknown

Also tag the shot itself:
- shot_type: face | upper_body | full_body | group | other
  - face: a head-and-shoulders framing where the face fills much of the frame
  - upper_body: roughly head to waist, one person
  - full_body: roughly head to feet / standing, one person
  - group: more than one person in frame
  - other: anything else (object, scenery, pet, unclear)
- usable_for_face: true only if there is exactly one clearly-visible, roughly
  front-facing face with the whole face in frame (not turned away, not heavily
  occluded, not tiny), otherwise false.
- usable_for_body: true only if there is exactly one person shown roughly
  full-length / standing with the body visible enough to assess (fitted or
  normal clothing, not a tight face crop), otherwise false.
