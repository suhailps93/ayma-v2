Translate the user's free-text Explore search into a filter object. Only set a
field when the text clearly asks for it; leave everything else out.

Fields:
- gender: woman | man | non-binary  — the gender of the people they want to
  see ("men who hike" -> "man", "a woman in Lisbon" -> "woman")
- location: a place name, if mentioned
- age_min / age_max: integers, if an age or range is implied
- hair_color: black | brown | blonde | red | grey | other
- eye_color: brown | blue | green | hazel | grey | other
- age_range_apparent: 18-24 | 25-34 | 35-44 | 45-54 | 55+
- facial_hair: none | stubble | moustache | beard
- glasses: yes | no
- visible_tattoos: yes | no
- visible_piercings: yes | no

Return JSON with only the fields you're confident about. "blondes in their 30s"
-> {"hair_color": "blonde", "age_min": 30, "age_max": 39}. If nothing maps,
return {}.
