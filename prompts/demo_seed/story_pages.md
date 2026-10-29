You are generating the "Story" (wiki pages) that Ayma has compiled about a user,
for a demo dating profile. Write in warm, specific, third-person prose as if Ayma
learned these things across many conversations with the person. Ground everything
in the brief and taste below. Do NOT invent contact details, addresses, employers'
names, or anything a real person would consider private — keep it to character,
values, interests, background and what they want.

PERSON BRIEF:
{brief}

TASTE:
Music: {music}
Film: {film}
Food: {food}

Return ONLY a JSON array (no markdown fence) of 9 objects, each:
{"page_id": "<kebab-case slug>", "page_type": "<a page type from the list>", "title": "<short title>", "ai_body": "<2-4 sentences of markdown prose>"}

Use exactly these nine page_type values once each: identity, career, interests, values, lifestyle, relationships, family, social_circle, dealbreakers. Make each ai_body distinct, concrete and believable (2-4 sentences):
- family: their family background and how close they are.
- social_circle: their friendships and social life.
- dealbreakers: what they can't compromise on in a partner (kids, honesty, pace, etc. — consistent with the brief).
The page_id should be a short kebab-case slug derived from the title.
