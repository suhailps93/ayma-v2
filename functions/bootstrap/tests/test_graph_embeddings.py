"""Strong dedupe candidate-finding (founder Nov 17): Gemini-embedding vectors
find candidates by nearest neighbour; the LiveKit judge still makes the call.

The real Google embedding call is MOCKED here (``_embed_backend``) — tests never
hit a provider. Covers: vectors stored per node + skip-unchanged + metering,
cosine nearest-neighbour, the semantic candidate report fed to the same judge,
and the flag gate (off → lexical path, no embedding).
"""

import dataclasses
import hashlib

import config
from config import CONFIG

import graph_embeddings as emb
import person_graph as pg
import person_graph_crosscheck as crosscheck
import person_graph_index as index_mod
import token_ledger


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _DocRef:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def collection(self, name):
        return _CollRef(self._st, self._key + (name,))

    def get(self):
        return _Snap(self._st.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._st.docs.get(self._key) or {}) if merge else {}
        cur.update(payload)
        self._st.docs[self._key] = cur


class _CollRef:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def document(self, name):
        return _DocRef(self._st, self._key + (name,))


class FakeDb:
    def __init__(self, overlay):
        self.docs = {("users", "u1", "graph", "main"): {"nodes": dict(overlay)}}

    def collection(self, name):
        return _CollRef(self, (name,))


def _overlay():
    return {
        "emergent.a": {"prompt": "Dog", "section": "misc", "level": 1,
                       "answer": "I have a brown tabby cat named Milo"},
        "emergent.b": {"prompt": "Pet", "section": "misc", "level": 1,
                       "answer": "my cat Milo is a brown tabby"},  # near-dup of a
        "emergent.c": {"prompt": "Job", "section": "career", "level": 1,
                       "answer": "I work as a data analyst in Lisbon"},  # far
    }


# Deterministic fake vectors: a & b point the same way (cosine≈1), c orthogonal.
_FAKE = {
    "I have a brown tabby cat named Milo": [1.0, 0.0, 0.0],
    "my cat Milo is a brown tabby": [0.98, 0.1, 0.0],
    "I work as a data analyst in Lisbon": [0.0, 0.0, 1.0],
}


def _mock_backend(texts):
    return [_FAKE.get(t, [0.0, 0.0, 0.0]) for t in texts]


def _on(monkeypatch):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, graph_embedding_dedupe=True)
    )
    monkeypatch.setattr(emb, "_embed_backend", _mock_backend)


def test_refresh_stores_a_vector_per_node_and_meters(monkeypatch):
    _on(monkeypatch)
    metered = []
    monkeypatch.setattr(token_ledger, "add",
                        lambda uid, feature, tokens, **k: metered.append((feature, k.get("provider"))))
    db = FakeDb(_overlay())
    n = emb.refresh_vectors(db, "u1")
    assert n >= 3  # every content-bearing node (the 3 emergent + seed prompts)
    vecs = emb.load_vectors(db, "u1")
    assert {"emergent.a", "emergent.b", "emergent.c"} <= set(vecs)
    # the embedding call was metered to the ledger, provider google.
    assert metered and metered[0] == ("graph_embedding", "google")
    # a re-run re-embeds nothing (content unchanged).
    assert emb.refresh_vectors(db, "u1") == 0


def test_flag_off_embeds_nothing(monkeypatch):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, graph_embedding_dedupe=False)
    )
    monkeypatch.setattr(emb, "_embed_backend", _mock_backend)
    db = FakeDb(_overlay())
    assert emb.refresh_vectors(db, "u1") == 0
    assert emb.load_vectors(db, "u1") == {}


def test_nearest_pairs_finds_the_near_pair_not_the_far_one():
    vectors = {"a": [1.0, 0.0], "b": [0.99, 0.1], "c": [0.0, 1.0]}
    pairs = emb.nearest_pairs(vectors, threshold=0.82)
    keys = {(a, b) for a, b, _ in pairs}
    assert ("a", "b") in keys
    assert not any("c" in (a, b) for a, b, _ in pairs)


def test_semantic_report_feeds_the_judge_the_near_pair(monkeypatch):
    _on(monkeypatch)
    db = FakeDb(_overlay())
    emb.refresh_vectors(db, "u1")
    vectors = emb.load_vectors(db, "u1")
    index = index_mod.build_index(db, "u1")
    report = crosscheck.find_candidates_semantic(index, vectors)
    ambiguous = {p.key() for p in report.ambiguous_pairs}
    # the near cat pair is an ambiguous candidate for the judge; the far job isn't.
    assert ("emergent.a", "emergent.b") in ambiguous
    assert not any("emergent.c" in k for k in ambiguous)


def test_candidate_report_routes_by_flag(monkeypatch):
    db = FakeDb(_overlay())
    index = index_mod.build_index(db, "u1")
    # flag ON → semantic (reason carries the cosine); first refresh the vectors.
    _on(monkeypatch)
    rep_on = crosscheck.candidate_report(db, "u1", index)
    assert any("semantic" in p.reason for p in rep_on.ambiguous_pairs) or \
        rep_on.duplicate_pairs  # cat pair surfaced via the embedding path
    # flag OFF → lexical path (no embedding call needed).
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, graph_embedding_dedupe=False)
    )
    rep_off = crosscheck.candidate_report(db, "u1", index)
    assert all("semantic" not in p.reason for p in rep_off.ambiguous_pairs)


def test_vectors_persist_across_shards_and_roundtrip(monkeypatch):
    """A real graph has hundreds of 3072-dim vectors — far past Firestore's 1 MiB
    per-document limit. Vectors must shard across sibling docs and round-trip
    exactly (NOTE 255 add.3: the single-doc store 400'd at 5.1 MB, so vectors
    never persisted). Here many nodes force several shards."""
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, graph_embedding_dedupe=True)
    )

    def _per_text(texts):
        # a deterministic distinct 8-float vector per text
        out = []
        for t in texts:
            seed = int(hashlib.sha1(t.encode()).hexdigest()[:8], 16)
            out.append([float((seed >> k) & 0xFF) for k in range(0, 64, 8)])
        return out

    monkeypatch.setattr(emb, "_embed_backend", _per_text)
    overlay = {
        f"emergent.n{i}": {"prompt": f"Q{i}", "section": "misc", "level": 1,
                           "answer": f"distinct fact number {i} about the person"}
        for i in range(emb._SHARD_SIZE * 2 + 5)  # force >2 shards
    }
    db = FakeDb(overlay)
    n = emb.refresh_vectors(db, "u1")
    assert n >= emb._SHARD_SIZE * 2 + 5
    vecs = emb.load_vectors(db, "u1")
    for i in range(emb._SHARD_SIZE * 2 + 5):
        assert f"emergent.n{i}" in vecs
    # more than one shard document was actually written.
    assert emb._shard_ref(db, "u1", 1).get().exists
    assert emb._shard_ref(db, "u1", 2).get().exists


def test_embed_backend_embeds_one_text_per_call(monkeypatch):
    """gemini-embedding-2 on Vertex returns ONE embedding per call regardless of
    how many contents are passed (NOTE 255 add.3). _embed_backend must loop so N
    texts yield N vectors — the old batch call returned 1, failing refresh's
    len-check so vectors never populated."""
    calls = []

    class _Emb:
        def __init__(self, v):
            self.values = v

    class _Resp:
        def __init__(self, v):
            self.embeddings = [_Emb(v)]

    class _Models:
        def embed_content(self, model, contents):
            calls.append(contents)
            return _Resp([float(len(calls)), 0.0])

    class _Client:
        def __init__(self, **kw):
            self.models = _Models()

    import google.genai as genai_mod
    monkeypatch.setattr(genai_mod, "Client", _Client)
    out = emb._embed_backend(["x", "y", "z"])
    assert out is not None and len(out) == 3
    assert calls == ["x", "y", "z"]  # one call per text, each a single string


# --- the union: lexical AND embedding candidates, never one replacing the other ---

_UNION_OVERLAY = {
    # a LEXICAL near-dup pair (high token overlap) whose vectors are orthogonal,
    # so only the lexical pass can find it.
    "emergent.l1": {"prompt": "Music", "section": "taste", "level": 1,
                    "answer": "Billie Eilish Bruno Mars Russ"},
    "emergent.l2": {"prompt": "Music", "section": "taste", "level": 1,
                    "answer": "Music Billie Eilish Bruno Mars Russ"},
    # a SEMANTIC-only pair (near-zero token overlap) whose vectors are near, so
    # only the embedding pass can find it.
    "emergent.s1": {"prompt": "Circle", "section": "social_circle", "level": 1,
                    "answer": "attentive listener shows up quietly"},
    "emergent.s2": {"prompt": "Circle", "section": "social_circle", "level": 1,
                    "answer": "friends value his careful listening habit"},
}

_UNION_FAKE = {
    "Billie Eilish Bruno Mars Russ": [1.0, 0.0, 0.0, 0.0],
    "Music Billie Eilish Bruno Mars Russ": [0.0, 1.0, 0.0, 0.0],  # orthogonal to l1
    "attentive listener shows up quietly": [0.0, 0.0, 1.0, 0.0],
    "friends value his careful listening habit": [0.0, 0.0, 0.99, 0.1],  # near s1
}


def test_candidate_report_unions_lexical_and_semantic(monkeypatch):
    """Flag ON must surface BOTH a lexical near-dup (embeddings rank it far) AND a
    semantic paraphrase (lexical misses it). The old code REPLACED lexical with
    embeddings, silently dropping the lexical duplicate (NOTE 255 add.3)."""
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, graph_embedding_dedupe=True)
    )
    monkeypatch.setattr(
        emb, "_embed_backend",
        lambda texts: [_UNION_FAKE.get(t, [0.0, 0.0, 0.0, 0.0]) for t in texts],
    )
    db = FakeDb(_UNION_OVERLAY)
    index = index_mod.build_index(db, "u1")
    rep = crosscheck.candidate_report(db, "u1", index)
    all_keys = {p.key() for p in rep.duplicate_pairs} | {p.key() for p in rep.related_pairs}
    lex_key = tuple(sorted(("emergent.l1", "emergent.l2")))
    sem_key = tuple(sorted(("emergent.s1", "emergent.s2")))
    assert lex_key in all_keys, "lexical near-dup lost when embeddings on"
    assert sem_key in all_keys, "semantic paraphrase not added by the union"
    # the semantic pair is handed to the judge (ambiguous), the lexical one too.
    assert sem_key in {p.key() for p in rep.ambiguous_pairs}
