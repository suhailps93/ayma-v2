"""Graph-backed read adapters for the live consumers (design §8.1, Phase 5b).

The person graph is the single source of truth; this module lets today's
consumers read it **without changing their math or output shape**. Each adapter
returns exactly what the old store read returned, built from the merged graph
(``seed ⊕ overlay``) instead of the questionnaire / profile / wiki documents.

Gated by ``CONFIG.person_graph_reads`` at the call site (flag off → the old
read path runs unchanged), so the switch is reversible and flag-off is today's
behaviour exactly.

What this swaps for the **deterministic scorer** (``match_deterministic`` via
``matching_skill._load_user``):

* ``qstore`` — the questionnaire subcollection ``{node_id: {"value": …}}`` —
  is rebuilt from the graph's answered seed nodes. The scorer's ``_typed_value``
  reads ``entry["value"]`` exactly as before; migration copied each
  questionnaire value verbatim onto its node, so the values are identical.
* ``profile`` — kept as the real ``profile/main`` doc (its gate fields —
  ``gender`` / ``interested_in`` / location / partner-age / ``completeness`` /
  ``trust_flags`` — are unchanged), **minus the ``qz_*`` questionnaire
  mirrors**, so the graph (not a stale mirror) is authoritative for a
  questionnaire answer once a user edits it through the graph tools.

Node ``weight`` stays the seed weight here (parity). Per-user relative weights
and emergent gates are Phase 5c, layered on top without touching this adapter.
"""

from __future__ import annotations

import logging

import person_graph as pg
import person_graph_store as store

logger = logging.getLogger("ayma.person_graph_source")


def structured_qstore(graph: dict[str, pg.GraphNode]) -> dict[str, dict]:
    """A questionnaire-store-shaped dict ``{node_id: {"value": answer}}`` from
    the answered **seed** nodes of ``graph``. Emergent (off-script) nodes carry
    non-seed ids the scorer never looks up, so they are skipped; narrative nodes
    are included but the scorer ignores narrative kinds. Mirrors the shape
    ``matching_skill._load_user`` built from the ``questionnaire`` subcollection.
    """
    out: dict[str, dict] = {}
    for nid, node in graph.items():
        if node.emergent:
            continue
        if node.answer in (None, ""):
            continue
        entry = {"value": node.answer}
        prov = getattr(node, "provenance", None)
        if prov is not None:
            entry["source"] = prov.value if hasattr(prov, "value") else str(prov)
        out[nid] = entry
    return out


def _strip_qz_mirrors(profile: dict) -> dict:
    """The profile doc without its ``qz_*`` questionnaire mirrors, so the graph
    is the single authority for a questionnaire answer. Every other profile
    field (gate inputs, completeness, name, location, trust) is kept as-is."""
    return {k: v for k, v in (profile or {}).items() if not str(k).startswith("qz_")}


def load_user(db, uid: str) -> tuple[dict, dict]:
    """Graph-backed ``(profile, qstore)`` — the drop-in for
    ``matching_skill._load_user`` when ``person_graph_reads`` is on. Best-effort:
    a graph read failure falls back to an empty qstore (profile still read), so
    scoring degrades exactly as the old path did on a missing store rather than
    raising."""
    base = db.collection("users").document(uid)
    profile: dict = {}
    try:
        snap = base.collection("profile").document("main").get()
        if snap is not None:
            profile = snap.to_dict() or {}
    except Exception:  # noqa: BLE001
        logger.exception("person_graph_source: profile read failed for %s", uid)

    qstore: dict = {}
    try:
        graph = store.effective(db, uid)
        qstore = structured_qstore(graph)
    except Exception:  # noqa: BLE001
        logger.exception("person_graph_source: graph read failed for %s", uid)

    return _strip_qz_mirrors(profile), qstore
