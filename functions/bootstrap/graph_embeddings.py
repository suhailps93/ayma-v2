"""Gemini-embedding vectors for person-graph nodes (founder Nov 17: strong
dedupe setup).

Every graph node (text and image) is embedded with Gemini Embedding 2 and the
vector is stored with the node. Dedupe + the related-node index then find
CANDIDATES by nearest-neighbour over these vectors instead of the lexical
pre-filter; the LiveKit judge (``person_graph_crosscheck.classify_pairs``) keeps
its job exactly — it decides duplicate / related / conflicting and real pairs are
raised in chat. Never silent, never an automatic merge on similarity alone.

PROVIDER ROUTE — founder-approved exception: the embedding call goes to Google
DIRECTLY (``google.genai``), the SAME shape as image generation, because the
LiveKit inference gateway has NO embedding endpoint (see
``person_graph_index`` doc). This is NOT a LiveKit reroute of chat/judge
inference — the judge stays on LiveKit. The model string lives only in
``config.py`` (``image_embedding_model`` = ``gemini-embedding-2``); the whole
path is gated OFF by default (``CONFIG.graph_embedding_dedupe``).
"""

from __future__ import annotations

import hashlib
import logging
import math
from typing import Optional

import person_graph_index as index_mod
import token_ledger
from config import CONFIG

logger = logging.getLogger("ayma.graph_embeddings")

# Side document holding the per-node vectors, separate from the overlay
# (``graph/main``) so a 3072-float vector per node never bloats the hot read.
_VEC_DOC = "vectors"
_GRAPH_COLLECTION = "graph"


def _vec_ref(db, uid: str):
    return (
        db.collection("users").document(uid)
        .collection(_GRAPH_COLLECTION).document(_VEC_DOC)
    )


def _content_hash(text: str) -> str:
    return hashlib.sha1((text or "").encode("utf-8")).hexdigest()[:16]


# A monkeypatch seam for tests: replace ``_embed_backend`` so nothing hits a
# real provider. Returns one vector per input text, or None on failure.
def _embed_backend(texts: list[str]) -> Optional[list[list[float]]]:
    """Call Gemini Embedding 2 directly (the founder-approved Google route).

    Lazy-imports the direct-Google SDK so module import never requires it (and
    tests patch this function out entirely). Returns None on any failure so the
    caller degrades to the lexical path."""
    if not texts:
        return []
    try:
        from google import genai  # lazy — only on the one authorized path

        if CONFIG.use_vertex:
            client = genai.Client(
                vertexai=True,
                project=CONFIG.project_id or None,
                location=CONFIG.gemini_location,
            )
        else:
            client = genai.Client()  # GOOGLE_API_KEY from the environment
        resp = client.models.embed_content(
            model=CONFIG.image_embedding_model,
            contents=texts,
        )
        return [list(e.values) for e in resp.embeddings]
    except Exception:  # noqa: BLE001 - embedding is best-effort; fall back lexically
        logger.warning("graph embedding call failed", exc_info=True)
        return None


def embed_texts(texts: list[str], *, uid: str | None = None) -> Optional[list[list[float]]]:
    """Embed ``texts``; meter the call in the token ledger (accounting only —
    embeddings are cheap, but the spend is still tracked per the founder's
    note). Returns one vector per text, or None if the backend failed."""
    vecs = _embed_backend(texts)
    if vecs is None:
        return None
    if uid:
        # Rough token estimate (no usage metadata on the embed response): ~4
        # chars/token. Accounting-only; drives the audit, not a hard cap.
        est = max(1, sum(len(t) for t in texts) // 4)
        try:
            token_ledger.add(
                uid, "graph_embedding", est,
                input_tokens=est,
                model=CONFIG.image_embedding_model,
                provider="google",
            )
        except Exception:  # noqa: BLE001 - metering must never block the embed
            logger.debug("graph_embedding metering failed for %s", uid)
    return vecs


def refresh_vectors(db, uid: str, *, intent: str | None = None) -> int:
    """Embed every indexable node whose content changed since last time and
    store the vector keyed by node id (with its content hash, so an unchanged
    node is never re-embedded). Prunes vectors for nodes that no longer exist.
    Returns the number of nodes (re-)embedded. Best-effort; gated by the flag."""
    from config import CONFIG as _cfg  # live read so a flag flip needs no restart

    if not _cfg.graph_embedding_dedupe:
        return 0
    index = [e for e in index_mod.build_index(db, uid, intent=intent) if e.indexable]
    stored = _load_raw(db, uid)
    to_embed: list[tuple[str, str, str]] = []  # (node_id, text, hash)
    for e in index:
        text = (e.text or "").strip()
        if not text:
            continue
        h = _content_hash(text)
        prev = stored.get(e.node_id)
        if isinstance(prev, dict) and prev.get("h") == h:
            continue
        to_embed.append((e.node_id, text, h))
    if to_embed:
        vecs = embed_texts([t for _, t, _ in to_embed], uid=uid)
        if vecs is None or len(vecs) != len(to_embed):
            return 0
        for (nid, _t, h), v in zip(to_embed, vecs):
            stored[nid] = {"h": h, "v": v}
    # prune vectors for deleted nodes
    live = {e.node_id for e in index}
    pruned = {nid: rec for nid, rec in stored.items() if nid in live}
    if to_embed or len(pruned) != len(stored):
        _save_raw(db, uid, pruned)
    return len(to_embed)


def _load_raw(db, uid: str) -> dict:
    try:
        snap = _vec_ref(db, uid).get()
        data = snap.to_dict() if snap and snap.exists else None
        return dict((data or {}).get("nodes") or {})
    except Exception:  # noqa: BLE001
        return {}


def _save_raw(db, uid: str, nodes: dict) -> None:
    _vec_ref(db, uid).set({"nodes": nodes, "model": CONFIG.image_embedding_model})


def load_vectors(db, uid: str) -> dict[str, list[float]]:
    """node_id → vector, for the stored, still-live nodes."""
    out: dict[str, list[float]] = {}
    for nid, rec in _load_raw(db, uid).items():
        if isinstance(rec, dict) and isinstance(rec.get("v"), list):
            out[nid] = [float(x) for x in rec["v"]]
    return out


def _cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def nearest_pairs(
    vectors: dict[str, list[float]], *, threshold: float, cap: int = 200
) -> list[tuple[str, str, float]]:
    """Candidate pairs (a, b, cosine) above ``threshold``, highest first, capped.
    This REPLACES the lexical pre-filter as the candidate source — the judge
    still decides each pair; a high cosine is only a candidate, never a merge."""
    ids = list(vectors)
    out: list[tuple[str, str, float]] = []
    for i in range(len(ids)):
        for j in range(i + 1, len(ids)):
            s = _cosine(vectors[ids[i]], vectors[ids[j]])
            if s >= threshold:
                out.append((ids[i], ids[j], s))
    out.sort(key=lambda t: t[2], reverse=True)
    return out[:cap]
