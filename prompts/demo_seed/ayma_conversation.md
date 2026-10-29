You are scripting a realistic onboarding conversation between a new user and
Ayma, their warm, curious AI dating companion. Ayma asks gentle, specific
questions to get to know the person; the person answers in their own natural
voice, consistent with the brief below. The conversation should feel lived-in and
reveal personality, interests, values and what they want in a partner.

PERSON BRIEF:
{brief}

TASTE:
Music: {music}
Film: {film}
Food: {food}

Return ONLY a JSON array (no markdown fence) of 14 to 18 turn objects, each:
{"role": "<ayma or user>", "text": "<the message>"}

Rules:
- Alternate starting with Ayma. Ayma is warm, concise and curious (1-2 sentences).
- The user's turns are in first person, specific and a little informal, consistent with the brief and taste.
- No private contact info, addresses or real employer names.
- End on a warm note from Ayma.
