"""Node-dedupe resolution tools, surfaced to Ayma in chat (founder Nov 17).

Resolution is NEVER silent: Ayma finds candidate duplicate / related nodes with
``pg_find_duplicates`` (read-only), presents them to the user the way a report
finding is confirmed, and applies the user's explicit choice with
``pg_resolve_duplicate`` — **merge** (fold one node into the other, retiring its
answer to history and rehoming its children), **link** (keep both, add a
Contract-4 ``related`` link), or **keep** (keep both, dismiss so the pair is not
raised again). Nothing is auto-deleted or auto-merged.

Gated behind ``CONFIG.node_dedupe`` (composed in ``skills/__init__``), off by
default. The find pass is the deterministic LEXICAL cross-check (no inference,
so the tool is cheap and fast); the semantic judge is reserved for the offline
staging runner.
"""

from __future__ import annotations

import logging
from typing import Callable

import person_graph_crosscheck as crosscheck
import person_graph_index as index_mod
import person_graph_store as store

from ._base import Skill

logger = logging.getLogger("ayma.node_dedupe")

# How many findings a single find call serialises back to the model.
_FIND_LIMIT = 12
_SNIPPET = 90


def _snippets(index) -> dict[str, str]:
    return {e.node_id: (e.text or "")[:_SNIPPET] for e in index}


# --- find ------------------------------------------------------------------

_FIND = {
    "name": "pg_find_duplicates",
    "description": (
        "Find pairs/groups of the user's person-graph nodes that say the SAME "
        "fact (duplicates) or are strongly RELATED (same topic, not identical) "
        "but are not parent/child. Read-only — it changes nothing. Use it before "
        "offering to tidy up duplicated content, then present the findings and "
        "let the user choose per pair: merge, link as related, or keep both "
        "(call pg_resolve_duplicate with their choice). Never merge without the "
        "user's say-so."
    ),
    "parameters": {"type": "object", "properties": {}},
}


def _bind_find(db, uid: str) -> Callable[..., str]:
    def pg_find_duplicates() -> str:
        try:
            index = index_mod.build_index(db, uid)
            report = crosscheck.candidate_report(db, uid, index)
            dismissed = store.dedupe_dismissed(db, uid)
        except Exception as exc:  # noqa: BLE001
            logger.warning("pg_find_duplicates failed for %s", uid, exc_info=True)
            return f"error: {exc}"

        snip = _snippets(index)
        lines: list[str] = []

        groups = [
            g for g in report.duplicate_groups()
            if not _group_fully_dismissed(g, dismissed)
        ]
        if groups:
            lines.append("DUPLICATES (same fact in more than one place):")
            for g in groups[:_FIND_LIMIT]:
                lines.append("  group: " + "; ".join(f"{n} [{snip.get(n,'')}]" for n in g))

        rel = [
            p for p in report.related_pairs
            if p.key() not in dismissed
        ]
        if rel:
            lines.append("RELATED (same topic, not identical):")
            for p in rel[:_FIND_LIMIT]:
                lines.append(
                    f"  {p.a} [{snip.get(p.a,'')}] ~ {p.b} [{snip.get(p.b,'')}] — {p.reason}"
                )

        # Pairs the background data-dedupe sweep (Layer 2) flagged as UNSURE and
        # recorded for the user to decide — the never-silent raise (founder Nov
        # 17). Surfaced here so Ayma brings them up in chat on the next session.
        try:
            pending = store.pending_dedupe(db, uid)
        except Exception:  # noqa: BLE001
            pending = []
        pending = [p for p in pending if (p["a"], p["b"]) not in dismissed]
        if pending:
            lines.append("NEEDS YOUR CALL (the dedupe sweep was unsure):")
            for p in pending[:_FIND_LIMIT]:
                reason = f" — {p['reason']}" if p.get("reason") else ""
                lines.append(
                    f"  {p['a']} [{snip.get(p['a'],'')}] ? {p['b']} [{snip.get(p['b'],'')}]{reason}"
                )

        if not lines:
            return "no duplicate or related candidates found"
        lines.append(
            "To act: pg_resolve_duplicate(action='merge'|'link'|'keep', "
            "survivor_id=<keep>, duplicate_id=<other>)."
        )
        return "\n".join(lines)

    return pg_find_duplicates


def _group_fully_dismissed(group: list[str], dismissed: set) -> bool:
    pairs = [
        (group[i], group[j])
        for i in range(len(group))
        for j in range(i + 1, len(group))
    ]
    keys = {(a, b) if a <= b else (b, a) for a, b in pairs}
    return bool(keys) and keys.issubset(dismissed)


# --- resolve ---------------------------------------------------------------

_RESOLVE = {
    "name": "pg_resolve_duplicate",
    "description": (
        "Apply the user's decision about two nodes pg_find_duplicates surfaced. "
        "action='merge' folds duplicate_id into survivor_id (keeps survivor_id, "
        "retires the other's content to history, rehomes its children, deletes "
        "it); action='link' keeps both and links them as related; action='keep' "
        "keeps both and stops the pair being raised again. Call ONLY after the "
        "user chooses."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["merge", "link", "keep"]},
            "survivor_id": {
                "type": "string",
                "description": "the node to keep (merge), or either node (link/keep)",
            },
            "duplicate_id": {
                "type": "string",
                "description": "the other node (merged away, linked, or kept)",
            },
            "label": {
                "type": "string",
                "description": "optional short reason for a related link",
            },
        },
        "required": ["action", "survivor_id", "duplicate_id"],
    },
}


def _bind_resolve(db, uid: str) -> Callable[..., str]:
    def pg_resolve_duplicate(
        action: str, survivor_id: str, duplicate_id: str, label: str = ""
    ) -> str:
        act = (action or "").strip().lower()
        # Whatever the user decides, this pair is resolved — stop the Layer-2
        # sweep from re-raising it in chat (founder Nov 17).
        try:
            store.clear_pending_dedupe(db, uid, survivor_id, duplicate_id)
        except Exception:  # noqa: BLE001
            pass
        try:
            if act == "merge":
                res = store.merge_nodes(db, uid, survivor_id, duplicate_id)
                return (
                    f"merged {res['removed']} into {res['survivor']} "
                    f"(rehomed {res['rehomed_children']} child node(s))"
                )
            if act == "link":
                added = store.link_related(
                    db, uid, survivor_id, duplicate_id, label=(label or None)
                )
                return (
                    f"linked {survivor_id} and {duplicate_id} as related"
                    if added else "already linked as related"
                )
            if act == "keep":
                store.dedupe_dismiss(db, uid, survivor_id, duplicate_id)
                return f"keeping both; won't raise {survivor_id}/{duplicate_id} again"
        except ValueError as exc:
            return f"error: {exc}"
        return f"error: unknown action {action!r} (use merge, link, or keep)"

    return pg_resolve_duplicate


# --- resolve a write-time CONFLICT (founder Nov 17, assessment part d) ------

_RESOLVE_CONFLICT = {
    "name": "pg_resolve_conflict",
    "description": (
        "Apply the user's decision about a CONFLICT the remember tool raised — a "
        "new fact that contradicted a note already in their graph (not a "
        "duplicate; the two answers can't both be true). Call ONLY after the user "
        "says which is right. keep='existing' discards the new fact and keeps the "
        "stored note unchanged. keep='incoming' overwrites the stored note's "
        "answer with new_value (the old value is retired to history, never shown "
        "publicly), so exactly one, resolved node remains — never two "
        "contradictory ones."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "node_id": {
                "type": "string",
                "description": "the existing node the new fact conflicted with",
            },
            "keep": {"type": "string", "enum": ["existing", "incoming"]},
            "new_value": {
                "type": "string",
                "description": "the new value to store when keep='incoming'",
            },
        },
        "required": ["node_id", "keep"],
    },
}


def _bind_resolve_conflict(db, uid: str) -> Callable[..., str]:
    def pg_resolve_conflict(
        node_id: str, keep: str, new_value: str = ""
    ) -> str:
        choice = (keep or "").strip().lower()
        if choice == "existing":
            return "kept your existing note; discarded the new one"
        if choice == "incoming":
            value = (new_value or "").strip()
            if not value:
                return "error: keep='incoming' needs new_value (the fact to store)"
            try:
                store.set_answer(db, uid, node_id, value)
            except ValueError as exc:
                return f"error: {exc}"
            return f"updated {node_id} to the new value (old value kept in history)"
        return f"error: unknown keep {keep!r} (use 'existing' or 'incoming')"

    return pg_resolve_conflict


SKILLS: list[Skill] = [
    Skill(declaration=_FIND, bind=_bind_find),
    Skill(declaration=_RESOLVE, bind=_bind_resolve),
]

# Write-time conflict raising (part d) is gated on its own flag, so its
# resolution tool is composed separately (``skills/__init__``) — present only
# when ``NODE_CONFLICT_RAISE`` is on.
CONFLICT_SKILLS: list[Skill] = [
    Skill(declaration=_RESOLVE_CONFLICT, bind=_bind_resolve_conflict),
]

SKILL_NAMES = {s.name for s in SKILLS} | {s.name for s in CONFLICT_SKILLS}
