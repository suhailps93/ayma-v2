"""Story-manage tools — always in BOTH the text chat and voice tool sets.

These are the plain-chat / live-call counterparts to the Your Story *editor*
tools in
``story_edit.py``. The editor tools only exist when the chat is opened from the
story screen with a specific page and highlighted passage in focus
(``story=True``); in the ordinary chat Ayma had no way to act when someone said
"change my story to say…" or "take that out of my story", so she'd fall back on
"I can't do that directly". These two tools close that gap:

* ``edit_story_entry`` — change ONE specific line/sentence of a story/wiki
  section to new wording, keeping every other line of the section byte-for-byte.
* ``remove_story_entry`` — take one line, or a whole section, off the user's
  story. A whole-section removal is a SOFT remove via the shared ``user_hidden``
  mechanism (:func:`story.remove_section`): the section is hidden from the story
  and the public profile, Ayma keeps its ``ai_body`` in her own notes, and the
  pre-remove state is committed to the section's version history first, so it is
  always revertible — never a hard, unrecoverable delete.

Both are **surgical**. ``edit_story_entry`` does not rewrite the whole section:
it locates the one line the user references (by their quoted/paraphrased text —
substring/fuzzy match on a line or sentence) and swaps only that line. When the
target line can't be confidently located — no good match, or two different lines
match about equally — neither tool overwrites anything; it returns a
clarification listing the candidate lines and asks which one, so a broad,
unintended overwrite can never happen silently (founder bug 2026-10-28: a
"change this one line" request rewrote the whole career section).

The edit is also robust against the model MISUSING the tool. A section is often
a single multi-sentence paragraph, so the whole body is itself a match
candidate; a model (especially on voice) may read the section back and pass the
whole paragraph as ``find_text`` and/or a whole rewrite as ``new_text``, which
once overwrote the entire Identity section (founder bug 2026-10-28, 3rd report).
So every write is reconciled sentence-by-sentence against the current body
(:func:`_surgical_merge`): only the sentences that genuinely changed are
written, every unchanged sentence is copied back byte-for-byte, and if what the
model passed would rewrite MOST of a multi-sentence section the tool refuses and
asks for the specific line instead of wiping it. The pre-edit wording is
snapshotted to the section's version history first, so every change is
revertible.

A direct user edit here applies **in place** and is done: ``story.save_section``
stamps a one-shot flag so the change is never re-surfaced as a pending "Public
profile updates" Apply/Dismiss card — a public line edited by the user stays
public, a private line stays private, with no re-approval. The propose/apply
flow is only for Ayma's own discovered additions.

Both resolve the section the user means by matching their words against the
titles / types / bodies of the caller's OWN story sections (``story.get_story``,
scoped to ``uid``) — they can never reach another user's wiki. Each returns a
plain confirmation string naming the section and the precise before/after so
Ayma tells the user exactly what happened rather than acting silently.
"""

from __future__ import annotations

import difflib
import re
from typing import Callable

import report_blocks as rb
import story

from ._base import Skill

_WORD_RE = re.compile(r"[a-z0-9]{3,}")
_STOPWORDS = frozenset(
    "the and for with what who how does did about their they them from have "
    "has was were are can section story entry part bit thing about please "
    "change edit update remove delete take out off say says said that this "
    "your you".split()
)

# Line-match thresholds. A paraphrase scores by difflib ratio; a quoted line is
# a substring either way. Below _MATCH_MIN there's no confident target; when a
# second, DIFFERENT line scores within _AMBIGUOUS_MARGIN of the best, it's
# ambiguous — in both cases we ask rather than overwrite.
_MATCH_MIN = 0.6
_AMBIGUOUS_MARGIN = 0.12
_SENTENCE_END = (".", "!", "?")

# A one-line edit should touch only a small slice of a multi-sentence section.
# If reconciling the model's wording against the current section would rewrite
# MOST of it, that isn't a single-line edit — the model handed a whole-section
# rewrite as `new_text`, or mis-targeted the whole section with `find_text`
# (founder bug 2026-10-28, 3rd report: a one-line change wiped the whole
# Identity section — the section is one paragraph, so the whole body is itself a
# match candidate and got overwritten). In that case we ask rather than
# overwrite. Only applied to sections with enough sentences to tell a one-line
# edit from a rewrite.
_MAX_CHANGED_FRACTION = 0.5
_REWRITE_MIN_SENTENCES = 2


def _terms(text: str) -> set[str]:
    return {w for w in _WORD_RE.findall((text or "").lower()) if w not in _STOPWORDS}


def _titles(sections: list[dict]) -> str:
    return ", ".join(f'"{s.get("title") or s.get("page_id")}"' for s in sections)


def _norm_ws(text: str) -> str:
    return " ".join((text or "").lower().split())


def _resolve_section(db, uid, section: str) -> tuple[dict | None, str | None]:
    """Find the one story section ``section`` names, among the caller's own.

    Returns ``(section_dict, None)`` on a confident single match, or
    ``(None, message)`` — a user-facing line naming the available sections —
    when there's nothing to match, the phrase is empty, or it's ambiguous."""
    sections = (story.get_story(db, uid) or {}).get("sections") or []
    if not sections:
        return None, "you don't have any story sections yet for me to change"
    q = (section or "").strip().lower()
    if not q:
        return None, "tell me which part of your story you mean and I'll change it"

    # 1) exact page_id or title.
    for s in sections:
        if str(s.get("page_id") or "").lower() == q:
            return s, None
    exact_title = [s for s in sections if str(s.get("title") or "").lower() == q]
    if len(exact_title) == 1:
        return exact_title[0], None

    # 2) a title that contains the phrase, or vice-versa.
    sub = [
        s
        for s in sections
        if q in str(s.get("title") or "").lower()
        or str(s.get("title") or "").lower() in q
    ]
    if len(sub) == 1:
        return sub[0], None

    # 3) keyword overlap against title / page_type / body — pick a clear winner.
    qterms = _terms(q)
    scored: list[tuple[int, dict]] = []
    for s in sections:
        hay = _terms(
            f"{s.get('title') or ''} {s.get('page_type') or ''} {s.get('body') or ''}"
        )
        score = len(qterms & hay)
        if score:
            scored.append((score, s))
    scored.sort(key=lambda t: t[0], reverse=True)
    if len(scored) == 1 or (
        len(scored) >= 2 and scored[0][0] > scored[1][0]
    ):
        return scored[0][1], None

    return None, (
        "I'm not sure which part you mean — your story has these sections: "
        f"{_titles(sections)}. Which one?"
    )


def _edit_body(s: dict) -> str:
    """The canonical body to edit and save back — ``edit_body`` keeps every
    ``{{private}}``/``{{ai_only}}`` span, so a surgical swap never drops them."""
    return str(s.get("edit_body") or s.get("body") or "")


def _candidate_units(body: str) -> list[str]:
    """Every line- and sentence-level unit of ``body``, each a verbatim
    (whitespace-trimmed) substring, deduped in first-seen order — so a matched
    unit can always be located back in ``body`` for an in-place swap."""
    units: list[str] = []
    seen: set[str] = set()

    def _add(u: str) -> None:
        u = u.strip()
        if u and u not in seen:
            seen.add(u)
            units.append(u)

    for line in (body or "").split("\n"):
        _add(line)
        for sent in rb.split_sentences(line):
            _add(sent)
    return units


def _visible_lines(body: str) -> list[str]:
    """The lines the user could point at, for a "which one?" clarification —
    the section's own lines, or its sentences when it's a single line/paragraph."""
    lines = [ln.strip() for ln in (body or "").split("\n") if ln.strip()]
    if len(lines) <= 1:
        sents = [p for p in rb.split_sentences(body or "") if p.strip()]
        if len(sents) > 1:
            return sents
    return lines


def _score(find_norm: str, cand_norm: str) -> float:
    if not find_norm or not cand_norm:
        return 0.0
    if find_norm == cand_norm:
        return 1.0
    if find_norm in cand_norm or cand_norm in find_norm:
        return 0.92
    return difflib.SequenceMatcher(None, find_norm, cand_norm).ratio()


def _locate_line(body: str, find_text: str) -> tuple[str | None, bool]:
    """The one unit of ``body`` the user's ``find_text`` references.

    Returns ``(unit, False)`` on a confident single match, ``(None, False)``
    when nothing matches well enough, and ``(None, True)`` when two genuinely
    different lines match about equally (ambiguous). Between a line and a
    sentence it contains (one is a substring of the other), the shorter — more
    specific — unit wins, so only that sentence is swapped, not the whole line."""
    q = _norm_ws(find_text)
    if not q:
        return None, False
    scored = sorted(
        ((_score(q, _norm_ws(c)), -len(c), c) for c in _candidate_units(body)),
        reverse=True,
    )
    if not scored or scored[0][0] < _MATCH_MIN:
        return None, False
    best = scored[0][2]
    best_score = scored[0][0]
    best_norm = _norm_ws(best)
    for sc, _neg_len, cand in scored[1:]:
        if best_score - sc > _AMBIGUOUS_MARGIN:
            break
        cand_norm = _norm_ws(cand)
        if cand_norm in best_norm or best_norm in cand_norm:
            continue  # same target at a different granularity, not a rival
        return None, True
    return best, False


def _replace_unit(body: str, unit: str, new_text: str) -> str:
    """``body`` with the first occurrence of ``unit`` swapped for ``new_text``,
    everything else byte-for-byte. Keeps the line's trailing sentence
    punctuation when the new wording drops it, so a reworded sentence doesn't
    lose its full stop."""
    idx = body.find(unit)
    if idx < 0:
        return body
    tail = ""
    if unit[-1:] in _SENTENCE_END and new_text[-1:] not in _SENTENCE_END:
        tail = unit[-1]
    return body[:idx] + new_text + tail + body[idx + len(unit):]


def _is_section_rewrite(body: str, new_text: str) -> bool:
    """True when ``new_text`` is a rewrite of the WHOLE section rather than a
    single replacement line — it has several sentences AND keeps a majority of
    the section's existing sentences verbatim (the model read the section back
    and changed one line inside it). Single-sentence ``new_text`` is never a
    rewrite, so a normal one-line edit stays on the ``find_text`` path."""
    body_sents = rb.split_sentences(body)
    new_sents = rb.split_sentences(new_text)
    if (
        len(body_sents) < _REWRITE_MIN_SENTENCES
        or len(new_sents) < _REWRITE_MIN_SENTENCES
    ):
        return False
    new_norm = _norm_ws(new_text)
    kept = sum(1 for s in body_sents if (n := _norm_ws(s)) and n in new_norm)
    return kept >= max(1, len(body_sents) // 2)


def _sentence_tokens(body: str) -> tuple[str, list[tuple[str, str]]] | None:
    """``(lead, [(sentence, trailing_glue), ...])`` such that ``lead`` plus every
    ``sentence + glue`` concatenated is ``body`` byte-for-byte. ``glue`` is the
    sentence-ending punctuation and whitespace up to the next sentence, so an
    unchanged sentence re-emits exactly as it was. ``None`` when a sentence piece
    can't be located back in ``body`` (so the caller declines rather than risk a
    lossy write)."""
    sents = rb.split_sentences(body)
    if not sents:
        return None
    spans: list[tuple[int, int]] = []
    pos = 0
    for s in sents:
        i = body.find(s, pos)
        if i < 0:
            return None
        spans.append((i, i + len(s)))
        pos = i + len(s)
    lead = body[: spans[0][0]]
    toks: list[tuple[str, str]] = []
    for k, (a, b) in enumerate(spans):
        nxt = spans[k + 1][0] if k + 1 < len(spans) else len(body)
        toks.append((body[a:b], body[b:nxt]))
    return lead, toks


def _surgical_merge(
    old: str, intended: str
) -> tuple[str | None, list[tuple[str, str]], int]:
    """Reconcile ``intended`` against ``old`` so the result differs from ``old``
    only in the sentences that genuinely changed — every unchanged sentence is
    copied back from ``old`` byte-for-byte (its punctuation and spacing with it).
    This is the guard that keeps a whole-section ``new_text`` (or a ``find_text``
    that matched the whole body) from blowing the section away: only the changed
    sentences are written.

    Returns ``(new_body, changed_pairs, n_total)`` — ``changed_pairs`` is the
    list of ``(before, after)`` sentence edits (a removed sentence is
    ``(before, "")``, an added one ``("", after)``), ``n_total`` the number of
    sentences in ``old``. ``new_body`` is ``None`` when ``old`` can't be
    tokenised safely."""
    told = _sentence_tokens(old)
    if told is None:
        return None, [], 0
    lead_o, toks_o = told
    tnew = _sentence_tokens(intended)
    toks_n = tnew[1] if tnew is not None else [
        (s, " ") for s in rb.split_sentences(intended)
    ]
    o_norm = [_norm_ws(s) for s, _ in toks_o]
    n_norm = [_norm_ws(s) for s, _ in toks_n]
    sm = difflib.SequenceMatcher(None, o_norm, n_norm, autojunk=False)
    out: list[str] = [lead_o]
    changed: list[tuple[str, str]] = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            for k in range(i1, i2):
                out.append(toks_o[k][0])
                out.append(toks_o[k][1])
            continue
        # Changed region: emit the NEW sentences (each with its own trailing
        # punctuation/spacing, so a reworded line keeps its full stop) and
        # record the before -> after pairs. A deleted sentence emits nothing.
        for off in range(max(i2 - i1, j2 - j1)):
            new_s, new_g = (
                toks_n[j1 + off] if j1 + off < j2 else ("", "")
            )
            old_s = toks_o[i1 + off][0] if i1 + off < i2 else ""
            if new_s:
                out.append(new_s)
                out.append(new_g)
            changed.append((old_s, new_s))
    return "".join(out), changed, len(toks_o)


def _remove_unit(body: str, unit: str) -> str:
    """``body`` with the first occurrence of ``unit`` removed, tidying the
    whitespace it leaves behind."""
    idx = body.find(unit)
    if idx < 0:
        return body
    out = body[:idx] + body[idx + len(unit):]
    out = re.sub(r"[ \t]{2,}", " ", out)
    out = re.sub(r" +\n", "\n", out)
    out = re.sub(r"\n{3,}", "\n\n", out)
    return out.strip()


def _which_line_msg(title: str, lines: list[str], ambiguous: bool = False) -> str:
    shown = "; ".join(f'"{ln}"' for ln in lines[:6])
    lead = (
        f'more than one line in your "{title}" could be the one you mean'
        if ambiguous
        else f"I couldn't find that exact line in your \"{title}\""
    )
    if shown:
        return f"{lead} — which of these should I change? {shown}"
    return f"{lead} — tell me the exact line you want changed"


_EDIT_DECL = {
    "name": "edit_story_entry",
    "description": (
        "Change ONE specific line/sentence of the user's own story/wiki to new "
        "wording when they ask you to correct or reword it — keeping every other "
        "line of that section exactly as it was. YOU CAN do this from an "
        "ordinary chat; you no longer need them to open the story editor. "
        "`section` names the part to change (its title, topic, or a few words "
        "from it); `find_text` is REQUIRED — pass the ONE existing line/sentence "
        "to change, copied VERBATIM (or very closely paraphrased) exactly as it "
        "reads now, NOT the whole section; `new_text` is ONLY that one line's "
        "corrected wording. NEVER pass the whole section, or more than the single "
        "changed line, as `new_text` or `find_text`: e.g. to change \"I speak "
        "Malayalam and English\" to add two languages, pass find_text=\"I speak "
        "Malayalam and English\" and new_text=\"I speak Malayalam, English, Hindi, "
        "and Tamil\" — never the paragraph around it. Only the one line changes, "
        "and if it was public it stays public (the edit applies in place, with no "
        "extra approval step). If you can't pin down which line they mean, the "
        "tool asks them to pick — it never overwrites, and it refuses to wipe a "
        "section when what you pass would rewrite most of it. The change is saved "
        "to history and is revertible. After it succeeds, tell them the precise "
        "before -> after in one line."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "section": {
                "type": "string",
                "description": (
                    "which story section the line is in — its title, topic, or a "
                    "short phrase from it (e.g. 'career', 'about my family')"
                ),
            },
            "find_text": {
                "type": "string",
                "description": (
                    "the existing line/sentence to change — quote it, or "
                    "paraphrase closely what it currently says"
                ),
            },
            "new_text": {
                "type": "string",
                "description": (
                    "the corrected wording to put in place of ONLY that one "
                    "line — not the whole section"
                ),
            },
        },
        "required": ["section", "find_text", "new_text"],
    },
}

_REMOVE_DECL = {
    "name": "remove_story_entry",
    "description": (
        "Take something off the user's own story/wiki when they ask you to "
        "remove or delete it. YOU CAN do this from an ordinary chat. If they "
        "point at ONE line/sentence, pass it as `line` and ONLY that line is "
        "removed, the rest of the section untouched. If they mean the whole "
        "section, omit `line`: that is a soft removal — the section is hidden "
        "from their story and public profile, you keep it in your own notes, and "
        "it can always be brought back, so it is safe and reversible. `section` "
        "names the part to act on (its title, topic, or a few words from it). If "
        "you can't pin down which line they mean, the tool asks them to pick — it "
        "never overwrites. After it succeeds, confirm in one line exactly what "
        "you removed."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "section": {
                "type": "string",
                "description": (
                    "which story section to act on — its title, topic, or a "
                    "short phrase from it"
                ),
            },
            "line": {
                "type": "string",
                "description": (
                    "optional — the one existing line/sentence to remove (quote "
                    "or closely paraphrase it). Omit to remove the whole section."
                ),
            },
        },
        "required": ["section"],
    },
}


def _bind_edit(db, uid: str) -> Callable[..., str]:
    def edit_story_entry(
        section: str = "", find_text: str = "", new_text: str = ""
    ) -> str:
        new_text = (new_text or "").strip()
        if not new_text:
            return "give me the new wording and I'll change that line"
        s, err = _resolve_section(db, uid, section)
        if err:
            return err
        page_id = str(s.get("page_id"))
        title = s.get("title") or page_id
        body = _edit_body(s)
        find = (find_text or "").strip()

        # Build the full new body the model is gesturing at. A whole-section
        # rewrite handed in `new_text` IS that body (ignore `find_text` — it was
        # likely the whole section quoted back); otherwise locate the one line
        # and splice the replacement in.
        if _is_section_rewrite(body, new_text):
            intended = new_text
        else:
            if not find:
                return _which_line_msg(title, _visible_lines(body))
            unit, ambiguous = _locate_line(body, find)
            if unit is None:
                return _which_line_msg(title, _visible_lines(body), ambiguous)
            intended = _replace_unit(body, unit, new_text)
            if intended == body:
                return _which_line_msg(title, _visible_lines(body))

        # Reconcile so ONLY genuinely-changed sentences differ and every
        # unchanged sentence stays byte-for-byte — this is the guard against a
        # whole-section overwrite even when the model targeted the whole section
        # or passed a full rewrite.
        new_body, changed, n_total = _surgical_merge(body, intended)
        if new_body is None or not changed or new_body == body:
            if new_body == body:
                return f'that line already reads that way in your "{title}"'
            return _which_line_msg(title, _visible_lines(body))
        if n_total >= 3 and len(changed) / n_total > _MAX_CHANGED_FRACTION:
            # Changing most of a multi-sentence section isn't a one-line edit —
            # ask rather than wipe it (founder bug 2026-10-28, 3rd report).
            return (
                f'that looks like a rewrite of most of your "{title}" section, '
                "not a one-line change — tell me the exact line to change and "
                "what it should say, and I'll change only that."
            )
        try:
            # Commit the current wording to history first, so this edit is
            # revertible to exactly what it said before.
            story._snapshot_section(
                db, uid, page_id, story.AUTHOR_USER, f"before chat edit of {title}"
            )
            story.save_section(
                db, uid, page_id, new_body, allow_hidden_changes=True
            )
        except KeyError:
            return "that section isn't there anymore"
        before = changed[0][0] or "(nothing)"
        after = changed[0][1] or "(removed)"
        more = "" if len(changed) == 1 else f" (and {len(changed) - 1} more)"
        return (
            f'done — in your "{title}" I changed only that line{more}: '
            f'"{before}" -> "{after}". '
            "Say the word if you want the old wording back."
        )

    return edit_story_entry


def _bind_remove(db, uid: str) -> Callable[..., str]:
    def remove_story_entry(section: str = "", line: str = "") -> str:
        s, err = _resolve_section(db, uid, section)
        if err:
            return err
        page_id = str(s.get("page_id"))
        title = s.get("title") or page_id
        target = (line or "").strip()
        if target:
            body = _edit_body(s)
            unit, ambiguous = _locate_line(body, target)
            if unit is None:
                return _which_line_msg(title, _visible_lines(body), ambiguous)
            new_body = _remove_unit(body, unit)
            if new_body.strip():
                try:
                    story._snapshot_section(
                        db, uid, page_id, story.AUTHOR_USER,
                        f"before chat removal of a line in {title}",
                    )
                    story.save_section(
                        db, uid, page_id, new_body, allow_hidden_changes=True
                    )
                except KeyError:
                    return "that section isn't there anymore"
                return (
                    f'took that line out of your "{title}": "{unit}". '
                    "The rest is unchanged — say the word to bring it back."
                )
            # Removing the only line empties the section → soft-remove it whole.
        try:
            story.remove_section(db, uid, page_id)
        except KeyError:
            return "that section isn't there anymore"
        return (
            f'removed "{title}" from your story — it\'s hidden now, '
            "just say the word and I'll bring it back"
        )

    return remove_story_entry


SKILLS: list[Skill] = [
    Skill(declaration=_EDIT_DECL, bind=_bind_edit),
    Skill(declaration=_REMOVE_DECL, bind=_bind_remove),
]
