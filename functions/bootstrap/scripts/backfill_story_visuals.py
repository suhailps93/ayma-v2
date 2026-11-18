#!/usr/bin/env python3
"""Backfill the write-time ``visual`` field on a user's pre-existing graph nodes
(founder order, Nov 18 2026).

The founder's story nodes predate the write-time visual-pick system, so they
carry no stored ``visual`` and the reader falls them back to a text row. This is
a one-off DATA pass: for every node in ``users/{uid}/graph/main`` that LACKS a
stored ``visual``, it sets ``visual`` from the settled palette (``node_visual``),
chosen by the node's ACTUAL content with DETERMINISTIC heuristics only — no
inference, no embeddings, no LiveKit.

Honest + conservative (founder rule: never fabricate structure out of a prose
sentence). The pick, in priority order per node:

  1. STANDARD identity field (the 6 known structured fields) -> ``gist_row``.
     The renderer draws a standard node as its labelled field via ``is_standard``
     (node_visualiser fallback path), so a diagram is NEVER forced on it.
  2. IMAGE node (effective ``answer_type == "image"``) -> ``photo_carousel``
     (params ``{}``; the renderer derives the refs from the node's image fields).
  3. DATED node (carries a real ``Link.dated``) -> ``timeline_entry``
     (``{date, title}``) — a real date is genuine structure.
  4. SCALED trait (seed ``kind == "scale"`` and the answer is a number) ->
     ``bar_meter`` (``{value, min, max, label}`` from the seed scale).
  5. Genuine LIST (seed ``kind == "multi"`` and the answer is a real list of
     >=1 items) -> ``chip_set`` (``{items}``).
  6. Everything else (prose narrative, single-choice enum, bool, opaque
     report_doc, ...) -> ``gist_row`` (a bullet). NEVER ``card``.

A node that ALREADY has a stored ``visual`` is left untouched.

Writes ONLY the nested ``visual`` field on each node, in a SINGLE atomic
``update`` keyed by ``FieldPath("nodes", <id>, "visual")`` — so no other node
field and not even the document ``updated_at`` is touched. Nothing is merged,
deleted, deduped, or raised.

STAGING ONLY. Refuses to run unless the active Firestore project is
ayma-staging.

    python3 scripts/backfill_story_visuals.py --uid <uid> --project ayma-staging --dry-run
    python3 scripts/backfill_story_visuals.py --uid <uid> --project ayma-staging --apply
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter

import node_visual
import person_graph as pg
import question_tree

_ALLOWED_PROJECT = "ayma-staging"


def _die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(2)


def _seed_by_id() -> dict[str, dict]:
    try:
        return {n["id"]: n for n in question_tree.nodes()}
    except Exception:  # noqa: BLE001 - seed must load; a failure is fatal, not silent
        _die("could not load the question_tree seed")
        return {}


def _is_number(val) -> bool:
    if isinstance(val, bool):
        return False
    if isinstance(val, (int, float)):
        return True
    if isinstance(val, str):
        try:
            float(val.strip())
            return True
        except (ValueError, AttributeError):
            return False
    return False


def _as_number(val):
    if isinstance(val, (int, float)):
        return val
    f = float(str(val).strip())
    return int(f) if f == int(f) else f


def _dated_of(entry: dict) -> str:
    for link in entry.get("links") or []:
        if isinstance(link, dict):
            d = (link.get("dated") or "").strip()
            if d:
                return d
    return ""


def _title_for(entry: dict) -> str:
    g = (entry.get("gist") or "").strip()
    if g:
        return g
    ans = entry.get("answer")
    return str(ans).strip() if isinstance(ans, str) else ""


def pick_visual(nid: str, entry: dict, seed_by_id: dict[str, dict]) -> tuple[dict, str]:
    """Return ``(visual_descriptor, reason)`` for a node lacking a stored visual.

    Deterministic; priority order matches the module docstring. ``reason`` is the
    palette type string used (``standard`` folds into ``gist_row`` in the store
    but is reported distinctly so the plan is auditable)."""
    seed = seed_by_id.get(nid) or {}
    seed_kind = seed.get("kind")
    at = entry.get("answer_type") or seed_kind
    answer = entry.get("answer")

    # 1. STANDARD identity field -> labelled view (gist_row; renderer labels it).
    if pg.is_standard(nid):
        return node_visual.make(node_visual.GIST_ROW), "standard"

    # 2. IMAGE node -> photo_carousel (renderer derives refs from image fields).
    if at == "image":
        return node_visual.make(node_visual.PHOTO_CAROUSEL), "photo_carousel"

    # 3. DATED node -> timeline_entry (a real date is genuine structure).
    dated = _dated_of(entry)
    title = _title_for(entry)
    if dated and title:
        return node_visual.timeline_entry(title, dated), "timeline_entry"

    # 4. SCALED trait -> bar_meter from the seed scale.
    scale = seed.get("scale") if isinstance(seed.get("scale"), dict) else None
    if seed_kind == "scale" and scale and _is_number(answer):
        lo = scale.get("min")
        hi = scale.get("max")
        if _is_number(lo) and _is_number(hi):
            label = (seed.get("label") or entry.get("prompt") or "").strip()
            return (
                node_visual.bar_meter(_as_number(answer), _as_number(lo), _as_number(hi), label),
                "bar_meter",
            )

    # 5. Genuine LIST -> chip_set.
    if seed_kind == "multi" and isinstance(answer, list):
        items = [str(x) for x in answer if str(x).strip()]
        if items:
            return node_visual.chip_set(items), "chip_set"

    # 6. Everything else -> a bullet.
    return node_visual.make(node_visual.GIST_ROW), "gist_row"


def _taste_ids(seed_by_id: dict[str, dict]) -> set[str]:
    """Seed node ids in the TASTE category (``page_type``/``section`` == taste)."""
    return {
        nid for nid, n in seed_by_id.items()
        if n.get("page_type") == "taste" or n.get("section") == "taste"
    }


def _is_taste_node(nid: str, entry: dict, taste_seed: set[str]) -> bool:
    return nid in taste_seed or entry.get("section") == "taste" or nid.startswith("taste_")


def _comma_items(answer) -> list[str]:
    """A stored value split into its comma-separated items, each trimmed, empties
    dropped. Non-string answers yield no items."""
    if not isinstance(answer, str):
        return []
    return [p.strip() for p in answer.split(",") if p.strip()]


def run_taste_refine(uid: str, *, apply: bool, db=None) -> dict:
    """Refine ONLY taste-category nodes (Astro's call, Nov 18): a taste node whose
    stored value is a GENUINE comma-separated LIST (>=2 items) is upgraded from a
    bullet to a ``chip_set`` carrying the split items. A taste node whose value is
    prose (no comma / a single item) is LEFT ``gist_row`` and named. The node's
    ``answer`` stays the full "A, B, C" string — only ``visual.params.items``
    carries the split. Never touches a node that already has a non-gist visual,
    never writes ``card``."""
    if db is None:
        from google.cloud import firestore as gcf
        db = gcf.Client()
    if getattr(db, "project", "") != _ALLOWED_PROJECT:
        _die(f"active project is {getattr(db, 'project', None)!r}, refusing "
             f"(expected {_ALLOWED_PROJECT!r})")

    seed_by_id = _seed_by_id()
    taste_seed = _taste_ids(seed_by_id)
    ref, data = _load_doc(db, uid)
    nodes = data.get("nodes") or {}

    from google.cloud.firestore_v1.field_path import FieldPath

    to_chip: dict[str, dict] = {}
    kept_prose: list[tuple[str, str]] = []
    skipped_nongist: list[tuple[str, str]] = []
    for nid, entry in nodes.items():
        if not isinstance(entry, dict) or not _is_taste_node(nid, entry, taste_seed):
            continue
        cur = (entry.get("visual") or {}).get("type")
        if cur != node_visual.GIST_ROW:
            # Only flip bullets; a node that already carries a real visual
            # (chip/card/photo/...) is left exactly as it is.
            skipped_nongist.append((nid, str(cur)))
            continue
        items = _comma_items(entry.get("answer"))
        if len(items) >= 2:
            to_chip[nid] = node_visual.chip_set(items)
        else:
            kept_prose.append((nid, repr(entry.get("answer"))))

    print(f"project={db.project}  uid={uid}  (taste refine)")
    print(f"taste-category nodes examined: "
          f"{sum(1 for nid,e in nodes.items() if isinstance(e,dict) and _is_taste_node(nid,e,taste_seed))}")
    print(f"--- to chip_set: {len(to_chip)} ---")
    for nid, vis in to_chip.items():
        print(f"  {nid}  items={vis['params']['items']}")
    print(f"--- left gist_row (prose / <2 items): {len(kept_prose)} ---")
    for nid, ans in kept_prose:
        print(f"  {nid}  answer={ans}")
    if skipped_nongist:
        print(f"--- taste nodes already non-gist (untouched): {len(skipped_nongist)} ---")
        for nid, vt in skipped_nongist:
            print(f"  {nid}  visual={vt}")

    if not apply:
        print("\nDRY-RUN: no writes. Only the `visual` field would flip gist_row->chip_set "
              "on the qualifying taste nodes; answers and all other fields untouched.")
        return {"to_chip": len(to_chip), "kept_prose": len(kept_prose)}

    if not to_chip:
        print("\nNothing to refine; no write issued.")
        return {"to_chip": 0, "kept_prose": len(kept_prose)}

    updates = {
        FieldPath("nodes", nid, "visual").to_api_repr(): vis
        for nid, vis in to_chip.items()
    }
    ref.update(updates)
    print(f"\nAPPLIED: flipped {len(updates)} taste node(s) gist_row->chip_set "
          f"(only the `visual` field touched).")
    return {"chipped": len(to_chip), "kept_prose": len(kept_prose),
            "plan": {nid: v for nid, v in to_chip.items()}}


# The 3 narrative taste restatements whose first chip still carries its own
# "<label>: " prefix (Astro call, Nov 18): the leading own-label is stripped so
# the chip shows the bare item. Same settled rule as the label-strip work —
# never store a node's own leading label.
_PREFIX_STRIP_NODES = (
    "emergent.story.c8d84e17",  # "Music: Billie Eilish" -> "Billie Eilish"
    "emergent.story.f7518a58",  # "Film: Iron Man"       -> "Iron Man"
    "emergent.story.0ff2c803",  # "Food: Wingstop"       -> "Wingstop"
)


def _strip_own_label(item: str) -> str:
    """Drop a leading ``"<label>: "`` prefix (everything up to and including the
    FIRST ``": "``). ``"Music: Billie Eilish"`` -> ``"Billie Eilish"``. No ``": "``
    present -> returned unchanged."""
    head, sep, tail = item.partition(": ")
    return tail if sep else item


def run_strip_taste_prefix(uid: str, *, apply: bool, db=None) -> dict:
    """Strip the leading own-label from ``visual.params.items[0]`` on the 3
    narrative taste restatements. Changes ONLY that one array (``items[0]``
    rewritten, every other item kept); nothing else on the node, and no other
    node, is touched. Only acts on a node that is a ``chip_set`` whose
    ``items[0]`` actually carries a ``"<label>: "`` prefix — otherwise it is left
    and named."""
    if db is None:
        from google.cloud import firestore as gcf
        db = gcf.Client()
    if getattr(db, "project", "") != _ALLOWED_PROJECT:
        _die(f"active project is {getattr(db, 'project', None)!r}, refusing "
             f"(expected {_ALLOWED_PROJECT!r})")

    ref, data = _load_doc(db, uid)
    nodes = data.get("nodes") or {}

    from google.cloud.firestore_v1.field_path import FieldPath

    updates: dict[str, list] = {}
    plan = []
    skipped = []
    for nid in _PREFIX_STRIP_NODES:
        entry = nodes.get(nid)
        if not isinstance(entry, dict):
            skipped.append((nid, "node missing"))
            continue
        vis = entry.get("visual") or {}
        if vis.get("type") != node_visual.CHIP_SET:
            skipped.append((nid, f"not chip_set (type={vis.get('type')!r})"))
            continue
        items = list((vis.get("params") or {}).get("items") or [])
        if not items:
            skipped.append((nid, "no items"))
            continue
        new0 = _strip_own_label(items[0])
        if new0 == items[0]:
            skipped.append((nid, f"items[0] has no '<label>: ' prefix ({items[0]!r})"))
            continue
        new_items = [new0] + items[1:]
        updates[nid] = new_items
        plan.append((nid, items[0], new0, new_items))

    print(f"project={db.project}  uid={uid}  (strip taste chip prefix)")
    print(f"--- to strip: {len(plan)} ---")
    for nid, old0, new0, new_items in plan:
        print(f"  {nid}")
        print(f"      items[0]: {old0!r} -> {new0!r}")
        print(f"      items (after): {new_items}")
    if skipped:
        print(f"--- skipped: {len(skipped)} ---")
        for nid, why in skipped:
            print(f"  {nid}: {why}")

    if not apply:
        print("\nDRY-RUN: no writes. Only `visual.params.items[0]` would change on "
              "the listed node(s); answers, other items and all other fields untouched.")
        return {"to_strip": len(plan), "skipped": len(skipped)}

    if not updates:
        print("\nNothing to strip; no write issued.")
        return {"to_strip": 0, "skipped": len(skipped)}

    # Rewrite ONLY the nested items array per node (one atomic update); leaves
    # visual.type/v, every other item, and the doc `updated_at` untouched.
    field_updates = {
        FieldPath("nodes", nid, "visual", "params", "items").to_api_repr(): new_items
        for nid, new_items in updates.items()
    }
    ref.update(field_updates)
    print(f"\nAPPLIED: stripped items[0] prefix on {len(field_updates)} node(s) "
          f"(only `visual.params.items` touched).")
    return {"stripped": len(updates), "skipped": len(skipped),
            "plan": {nid: it for nid, it in updates.items()}}


def _load_doc(db, uid: str):
    ref = (
        db.collection("users").document(uid)
        .collection("graph").document("main")
    )
    snap = ref.get()
    if not (snap and snap.exists):
        _die(f"no graph/main doc for uid={uid!r} in project {db.project!r}")
    return ref, (snap.to_dict() or {})


def run(uid: str, *, apply: bool, db=None) -> dict:
    if db is None:
        from google.cloud import firestore as gcf
        db = gcf.Client()
    if getattr(db, "project", "") != _ALLOWED_PROJECT:
        _die(f"active project is {getattr(db, 'project', None)!r}, refusing "
             f"(expected {_ALLOWED_PROJECT!r})")

    seed_by_id = _seed_by_id()
    ref, data = _load_doc(db, uid)
    nodes = data.get("nodes") or {}
    if not isinstance(nodes, dict):
        _die("graph/main has no 'nodes' map")

    from google.cloud.firestore_v1.field_path import FieldPath

    plan: dict[str, dict] = {}   # nid -> visual
    reasons = Counter()
    samples: dict[str, list] = {}
    already = 0
    for nid, entry in nodes.items():
        if not isinstance(entry, dict):
            continue
        if entry.get("visual") is not None:
            already += 1
            continue
        visual, reason = pick_visual(nid, entry, seed_by_id)
        plan[nid] = visual
        reasons[reason] += 1
        samples.setdefault(reason, [])
        if len(samples[reason]) < 6:
            samples[reason].append(nid)

    # Report: counts, reason -> store-type, samples.
    print(f"project={db.project}  uid={uid}")
    print(f"total nodes={len(nodes)}  already-visual(left as-is)={already}  "
          f"to-convert={len(plan)}")
    print("--- assignment by chosen pick ---")
    for reason in ("photo_carousel", "timeline_entry", "bar_meter", "chip_set",
                   "standard", "gist_row"):
        if reasons.get(reason):
            store_t = "gist_row" if reason == "standard" else reason
            label = reason + (f" (stored type={store_t})" if reason == "standard" else "")
            print(f"  {label}: {reasons[reason]}   samples: {samples.get(reason, [])}")
    total_gist = reasons.get("gist_row", 0) + reasons.get("standard", 0)
    print(f"--- stored-type totals: photo_carousel={reasons.get('photo_carousel',0)} "
          f"timeline_entry={reasons.get('timeline_entry',0)} "
          f"bar_meter={reasons.get('bar_meter',0)} chip_set={reasons.get('chip_set',0)} "
          f"gist_row={total_gist} (incl. {reasons.get('standard',0)} standard) ---")

    if not apply:
        print("\nDRY-RUN: no writes. Only the `visual` field would be added per node; "
              "every other field and the doc `updated_at` are left untouched.")
        return {"to_convert": len(plan), "already": already, "reasons": dict(reasons)}

    if not plan:
        print("\nNothing to convert; no write issued.")
        return {"to_convert": 0, "already": already, "reasons": dict(reasons)}

    # Single atomic update of ONLY the nested visual fields (one write / doc).
    # Keys are escaped field-path strings (``to_api_repr`` backtick-quotes a node
    # id containing dots) so Firestore sets exactly ``nodes.<id>.visual`` and
    # leaves every sibling field — and the doc ``updated_at`` — untouched.
    updates = {
        FieldPath("nodes", nid, "visual").to_api_repr(): visual
        for nid, visual in plan.items()
    }
    ref.update(updates)
    print(f"\nAPPLIED: single update set {len(updates)} `visual` fields "
          f"(no other field touched).")
    return {"converted": len(plan), "already": already, "reasons": dict(reasons),
            "plan": {nid: v for nid, v in plan.items()}}


def main() -> None:
    ap = argparse.ArgumentParser(description="Backfill graph node `visual` field (staging only).")
    ap.add_argument("--uid", required=True)
    ap.add_argument("--project", default="")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--taste-refine", action="store_true",
                    help="only upgrade comma-list taste nodes gist_row->chip_set")
    ap.add_argument("--strip-taste-prefix", action="store_true",
                    help="strip the leading '<label>: ' from items[0] of the 3 taste restatements")
    args = ap.parse_args()
    if args.project and args.project != _ALLOWED_PROJECT:
        _die(f"--project must be {_ALLOWED_PROJECT!r} (got {args.project!r})")
    if args.apply and args.dry_run:
        _die("pass only one of --dry-run / --apply")
    apply = args.apply and not args.dry_run
    if args.strip_taste_prefix:
        run_strip_taste_prefix(args.uid, apply=apply)
    elif args.taste_refine:
        run_taste_refine(args.uid, apply=apply)
    else:
        run(args.uid, apply=apply)


if __name__ == "__main__":
    main()
