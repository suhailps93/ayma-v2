"""Deep-dive web research on a named person (§ deep dive).

Given a full name (+ optional disambiguating context) this runs a two-step
Gemini pass:

1. a grounded research call (``google_search`` + ``url_context``) that sweeps
   the open web and writes up what it finds, with source links;
2. a structured digest of that write-up — a short "who this appears to be",
   the specific claims (each with a source and a confidence), and the links
   (each flagged likely / maybe / unclear as being the same person).

Two callers:

* the user on **themselves** — "look me up so I don't have to repeat it".
  Ayma then walks the digest with them; their confirmations land in the wiki
  through the normal ingest path (nothing is written to the wiki here).
* the user on **someone they're meeting** — a private research note shown only
  to them. Never written to anyone's wiki.
"""

from __future__ import annotations

import logging

import gemini
import schema
from token_ledger import FEATURE_DEEPDIVE

logger = logging.getLogger("ayma.deepdive")


def _profile_dict(db, uid: str) -> dict:
    try:
        return schema.profile_doc(db, uid).get().to_dict() or {}
    except Exception:  # noqa: BLE001 - a profile read must never break a lookup
        return {}


def profile_full_name(db, uid: str) -> str:
    """The subject's research name: ``"{first_name} {last_name}"`` when the
    profile carries both, else the plain ``name`` field (``""`` if neither)."""
    data = _profile_dict(db, uid)
    first = str(data.get("first_name", "")).strip()
    last = str(data.get("last_name", "")).strip()
    if first and last:
        return f"{first} {last}"
    return str(data.get("name", "")).strip()


def profile_dive_context(db, uid: str) -> str:
    """Extra disambiguation drawn from the user's own profile for a *self*
    lookup — location as plain context, and the phone number as a
    use-only-to-disambiguate note that is never fed into the search query."""
    data = _profile_dict(db, uid)
    bits: list[str] = []
    loc = str(data.get(schema.PF_LOCATION, "")).strip()
    if loc:
        bits.append(f"Location: {loc}.")
    phone = str(data.get("phone", "")).strip()
    if phone:
        bits.append(
            f"(the user also gave the phone number {phone} — only use it to "
            f"disambiguate, never publish or repeat it)"
        )
    return " ".join(bits)

_RESEARCH_SYSTEM = (
    "You are a careful open-source researcher. You are given a person's full "
    "name and some context. Search the web thoroughly — professional profiles, "
    "company pages, news, talks, papers, personal sites, social profiles, "
    "directories. Report everything you can attribute to this specific person, "
    "always noting the source URL. Where several people share the name, say so "
    "and separate them. Do not invent anything; if the web is thin, say that. "
    "This is a consented lookup — either the person researching themselves, or "
    "someone doing normal due diligence before a date."
)

_DIGEST_SYSTEM = (
    "Turn the research notes into a compact JSON digest. Be conservative: only "
    "include a claim if the notes support it, and set confidence honestly. "
    "`is_them` on each link says how sure we are the link is about THIS person "
    "(same name alone is 'maybe'). Keep `summary` to 2-4 plain sentences."
)

_DIGEST_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "confidence": {
            "type": "string",
            "enum": ["high", "medium", "low", "not_found"],
        },
        "facts": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "claim": {"type": "string"},
                    "category": {
                        "type": "string",
                        "description": "work | education | location | "
                        "projects | writing | press | social | other",
                    },
                    "source_url": {"type": "string"},
                    "confidence": {
                        "type": "string",
                        "enum": ["high", "medium", "low"],
                    },
                },
                "required": ["claim", "category", "confidence"],
            },
        },
        "links": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "url": {"type": "string"},
                    "title": {"type": "string"},
                    "is_them": {
                        "type": "string",
                        "enum": ["likely", "maybe", "unclear"],
                    },
                    "note": {"type": "string"},
                },
                "required": ["url", "is_them"],
            },
        },
        "caveats": {"type": "string"},
    },
    "required": ["summary", "confidence", "facts", "links"],
}

_MAX_NAME = 120
_MAX_CONTEXT = 600


async def run(
    name: str,
    *,
    uid: str | None = None,
    context: str = "",
    is_self: bool = False,
) -> dict:
    """Research ``name`` and return
    ``{name, summary, confidence, facts, links, caveats, is_self}``.

    Raises ``ValueError`` for an empty name. Metered to ``uid`` under the
    ``deepdive`` feature; a cap hit propagates ``TokenCapExceeded``."""
    name = (name or "").strip()[:_MAX_NAME]
    if not name:
        raise ValueError("a full name is required")
    context = (context or "").strip()[:_MAX_CONTEXT]

    who = "yourself" if is_self else "this person"
    ask = (
        f"Full name: {name}\n"
        f"Context: {context or '(none given)'}\n\n"
        f"Research {who} and write up everything you can find, with source "
        f"URLs inline."
    )
    prose, sources = await gemini.research(
        ask,
        system_prompt=_RESEARCH_SYSTEM,
        uid=uid,
        feature=FEATURE_DEEPDIVE,
        max_output_tokens=6000,
    )

    src_lines = "\n".join(
        f"- {s['url']}  ({s.get('title', '')})" for s in sources
    )
    digest = await gemini.generate_json(
        f"Full name: {name}\nContext: {context or '(none)'}\n\n"
        f"RESEARCH NOTES:\n{prose or '(the search returned little)'}\n\n"
        f"SOURCE LINKS SEEN:\n{src_lines or '(none)'}",
        system_prompt=_DIGEST_SYSTEM,
        response_schema=_DIGEST_SCHEMA,
        uid=uid,
        feature=FEATURE_DEEPDIVE,
    )
    if not isinstance(digest, dict):
        digest = {}

    return {
        "name": name,
        "is_self": is_self,
        "summary": str(digest.get("summary", "")).strip(),
        "confidence": str(digest.get("confidence", "not_found")),
        "facts": [f for f in (digest.get("facts") or []) if isinstance(f, dict)],
        "links": [ln for ln in (digest.get("links") or []) if isinstance(ln, dict)],
        "caveats": str(digest.get("caveats", "")).strip(),
    }


def render(digest: dict) -> str:
    """A short chat-ready summary of a :func:`run` result — what Ayma says
    before she starts confirming details with the user."""
    name = digest.get("name", "them")
    conf = digest.get("confidence", "not_found")
    if conf == "not_found" or (not digest.get("facts") and not digest.get("summary")):
        return (
            f"I searched the web for {name} and didn't find much I could "
            f"confidently pin to one person. Want to tell me the basics yourself?"
        )

    lines = [digest.get("summary", "").strip()]
    facts = digest.get("facts") or []
    if facts:
        lines.append("")
        for f in facts[:8]:
            claim = str(f.get("claim", "")).strip()
            if claim:
                lines.append(f"- {claim}")
    links = [ln for ln in (digest.get("links") or []) if ln.get("url")]
    if links:
        lines.append("")
        lines.append("Links I think are you/them:")
        for ln in links[:6]:
            tag = ln.get("is_them", "unclear")
            lines.append(f"- [{ln.get('title') or ln['url']}]({ln['url']}) ({tag})")
    if digest.get("caveats"):
        lines.append("")
        lines.append(f"_{digest['caveats']}_")
    lines.append("")
    lines.append(
        "Which of these are right, and is anything off or missing?"
        if digest.get("is_self")
        else "Anything here you want me to keep in mind, or that looks wrong?"
    )
    return "\n".join(x for x in lines if x is not None).strip()
