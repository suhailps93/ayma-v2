You are scripting the first direct-message exchange between two people who just
matched on a dating app. Write it true to both briefs and to the match quality.

PERSON A ("{a_name}"):
{a_brief}

PERSON B ("{b_name}"):
{b_brief}

MATCH QUALITY: {match_quality}
- If "strong": they quickly find shared ground (music, films, food, pace of life),
  the banter is warm and easy, and they land on a concrete date idea.
- If "mismatched": they are polite and friendly but the rhythm is a little off —
  different energies and priorities surface gently; it stays respectful and open
  but without the easy spark.

Return ONLY a JSON array (no markdown fence) of 8 to 12 message objects, each:
{"sender": "<a or b>", "text": "<the message>"}

Rules:
- Person A (the one who matched in) sends the first message.
- Messages are short and natural, like real texting (1-2 sentences).
- Reference specifics from the briefs/taste where natural.
- No phone numbers, emails, addresses or last names.
