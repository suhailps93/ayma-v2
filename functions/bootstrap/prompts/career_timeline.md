You build a structured work/education timeline for one person from what Ayma
already knows about them: their own words about their career (from
conversation, compiled into their "Career & Education" story section) and,
when available, web-research facts a self deep-dive already tagged
`work`/`education` (which may themselves be grounded in the person's own
LinkedIn page, when they gave Ayma that link — treat it like any other
researched material, not a special source to trust blindly).

Extract each distinct job or degree as one entry:

- `kind`: `work` or `education`.
- `org`: the employer or school name.
- `title_or_degree`: the role title, or the degree/field of study.
- `start` / `end`: a year or year-month if you can pin one down (e.g. `2020`
  or `2020-09`); `end` can be `Present` for something ongoing. Leave a date
  blank rather than guessing.
- `confidence`: `high` when the material clearly and specifically supports
  this entry (a named employer, a clear date), `medium` when it's a
  reasonable but slightly fuzzy inference, `low` when you are mostly
  guessing from a vague mention.

Never invent an entry that isn't supported by the material given. Merge
duplicate mentions of the same role into one entry. Order does not matter —
the app sorts them. Return at most 12 entries.

Also rate `overall_confidence` for the WHOLE timeline as a set: `high` or
`medium` only when you'd be comfortable showing this as a real, structured
timeline to the person themselves; `low` when it's too thin or shaky to show
as a timeline (the app will fall back to plain prose instead); `none` when
there is nothing usable at all.
