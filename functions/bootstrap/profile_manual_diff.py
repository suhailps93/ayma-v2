"""Sentence-level diffing and model classification of profile edits.

Tier-2 sweep monolith split #12: the ``--- diffing ---`` section of the
former ``profile_manual.py`` monolith, moved verbatim — no behavior change.
"""

from __future__ import annotations

import difflib
import logging

import gemini
import report_blocks as rb
import token_ledger
from profile_manual_common import (
    KIND_ADDED,
    KIND_REMOVED,
    _CLASSIFY_SCHEMA,
    _KINDS,
    _norm,
    _prompt,
)

logger = logging.getLogger("ayma.profile_manual")


def _blocks(before: str, after: str) -> list[dict]:
    b = rb.split_sentences(before)
    a = rb.split_sentences(after)
    sm = difflib.SequenceMatcher(
        None, [_norm(x) for x in b], [_norm(x) for x in a], autojunk=False
    )
    return [
        {"removed": b[i1:i2], "added": a[j1:j2]}
        for tag, i1, i2, j1, j2 in sm.get_opcodes()
        if tag != "equal"
    ]


def diff_segments(before: str, after: str) -> list[dict]:
    """Sentence-level diff for display: ``[{op: same|add|remove, text}]``."""
    b = rb.split_sentences(before)
    a = rb.split_sentences(after)
    sm = difflib.SequenceMatcher(
        None, [_norm(x) for x in b], [_norm(x) for x in a], autojunk=False
    )
    out: list[dict] = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            out += [{"op": "same", "text": t} for t in b[i1:i2]]
            continue
        out += [{"op": "remove", "text": t} for t in b[i1:i2]]
        out += [{"op": "add", "text": t} for t in a[j1:j2]]
    return out


async def _classify(uid: str, blocks: list[dict]) -> dict[str, str]:
    """``{sentence id: kind}`` — ``r<n>`` ids default to ``removed_fact`` and
    ``a<n>`` to ``added_fact`` (the safe reading) for anything the model does
    not answer, or if the call fails."""
    lines: list[str] = []
    verdicts: dict[str, str] = {}
    for n, blk in enumerate(blocks, 1):
        lines.append(f"Block {n} (section: {blk['title']})")
        lines.append("REMOVED:")
        for sent_id, text in blk["removed_ids"]:
            lines.append(f"{sent_id}: {text}")
            verdicts[sent_id] = KIND_REMOVED
        lines.append("ADDED:")
        for sent_id, text in blk["added_ids"]:
            lines.append(f"{sent_id}: {text}")
            verdicts[sent_id] = KIND_ADDED
        lines.append("")
    try:
        result = await gemini.generate_json(
            "\n".join(lines),
            system_prompt=_prompt("profile_diff_classify.md"),
            response_schema=_CLASSIFY_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_PROFILE_MANUAL,
            enforce_cap=False,
        )
    except Exception:  # noqa: BLE001 - fall back to the safe defaults
        logger.exception("profile diff classification failed for %s", uid)
        return verdicts
    for item in (result or {}).get("items", []) if isinstance(result, dict) else []:
        if (
            isinstance(item, dict)
            and item.get("id") in verdicts
            and item.get("kind") in _KINDS
        ):
            verdicts[item["id"]] = item["kind"]
    return verdicts
