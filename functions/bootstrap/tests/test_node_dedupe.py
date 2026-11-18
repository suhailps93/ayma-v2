"""Tests for the node-dedupe index, cross-check, and resolution (founder Nov 17)."""

import asyncio
import dataclasses

import pytest

import config
import gemini
import person_graph as pg
import person_graph_crosscheck as crosscheck
import person_graph_index as index_mod
import person_graph_store as store
from person_graph import NodeState, Provenance, Visibility


# --- a minimal Firestore fake (collection/document/get/set) ----------------


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
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def collection(self, name):
        return _CollRef(self, (name,))


UID = "u1"


def _node(nid, section, level, *, answer=None, parent=None, answer_type="narrative",
          image_read=None, visibility=Visibility.PRIVATE, emergent=True, prompt=None):
    return pg.GraphNode(
        id=nid, section=section, level=level, weight=0.0,
        prompt=prompt or nid, answer=answer, answer_type=answer_type,
        parent=parent, image_read=image_read, visibility=visibility,
        emergent=emergent,
        state=NodeState.ANSWERED if answer or image_read else NodeState.NOT_ASKED,
    )


# --- index -----------------------------------------------------------------


def test_index_covers_every_kind_and_uses_image_read():
    graph = {
        "emergent.editor.career.0": _node(
            "emergent.editor.career.0", "career", 2, answer="I work at Google as a PM"
        ),
        "emergent.skill.web_findings": _node(
            "emergent.skill.web_findings", "career", 2,
            answer="Works at Google as a product manager", answer_type="narrative"
        ),
        "emergent.image.abc": _node(
            "emergent.image.abc", "misc", 3, answer="https://x/pic.jpg",
            answer_type="image", image_read="A man hiking on a mountain trail",
            parent="emergent.editor.career.0",
        ),
    }
    idx = index_mod.index_from_graph(graph)
    by_id = {e.node_id: e for e in idx}
    # image node indexes its READ text, not the storage URL
    img = by_id["emergent.image.abc"]
    assert img.kind == index_mod.KIND_IMAGE
    assert "hiking" in img.text and "http" not in img.text
    assert "emergent.editor.career.0" in img.ancestors  # parent chain captured
    assert by_id["emergent.skill.web_findings"].kind == index_mod.KIND_GROUNDING


def test_normalize_and_exact_match():
    graph = {
        "a": _node("a", "misc", 2, answer="I love Thai food!"),
        "b": _node("b", "misc", 2, answer="i  love thai food"),
    }
    idx = index_mod.index_from_graph(graph)
    assert index_mod.find_exact_match(idx, "I LOVE thai food") in ("a", "b")
    assert index_mod.find_exact_match(idx, "something else") is None


# --- cross-check -----------------------------------------------------------


def test_exact_duplicate_across_sections_flagged():
    graph = {
        "a": _node("a", "career", 2, answer="I work at Google as a PM"),
        "b": _node("b", "misc", 2, answer="I work at Google as a PM"),
    }
    report = crosscheck.find_candidates(index_mod.index_from_graph(graph))
    assert report.duplicate_pairs
    p = report.duplicate_pairs[0]
    assert p.relation == crosscheck.EXACT
    assert {p.a, p.b} == {"a", "b"}


def test_ancestor_descendant_pair_not_flagged():
    graph = {
        "parent": _node("parent", "career", 2, answer="I work at Google as a PM"),
        "child": _node("child", "career", 3, answer="I work at Google as a PM",
                       parent="parent"),
    }
    report = crosscheck.find_candidates(index_mod.index_from_graph(graph))
    assert not report.duplicate_pairs  # parent/child is structure, not a dup


def test_near_duplicate_and_related():
    graph = {
        "a": _node("a", "career", 2, answer="Senior product manager at Google"),
        "b": _node("b", "misc", 2, answer="Senior product manager at Google Inc"),
        "c": _node("c", "career", 2, answer="Left Google to become a product designer"),
    }
    report = crosscheck.find_candidates(index_mod.index_from_graph(graph))
    dup_keys = {p.key() for p in report.duplicate_pairs}
    assert ("a", "b") in dup_keys  # near-duplicate
    # a/c share the entities 'google' + 'product' -> related, NOT a duplicate
    rel_keys = {p.key() for p in report.related_pairs}
    assert ("a", "c") in rel_keys
    assert ("a", "c") not in dup_keys


def test_duplicate_groups_connected_components():
    graph = {
        "a": _node("a", "career", 2, answer="I work at Google as a PM"),
        "b": _node("b", "misc", 2, answer="I work at Google as a PM"),
        "c": _node("c", "hobbies", 2, answer="I work at Google as a PM"),
    }
    report = crosscheck.find_candidates(index_mod.index_from_graph(graph))
    groups = report.duplicate_groups()
    assert len(groups) == 1 and set(groups[0]) == {"a", "b", "c"}


# --- resolution: merge -----------------------------------------------------


def _profile(uid, intent="long_term"):
    return {("users", uid, "profile", "main"): {"relationship_intent": intent}}


def _overlay_doc(uid, nodes):
    return {("users", uid, "graph", "main"): {"nodes": nodes}}


def test_merge_folds_answer_rehomes_children_and_deletes():
    nodes = {
        "survivor": {
            "prompt": "job", "section": "career", "level": 2,
            "answer_type": "narrative", "answer": "PM at Google",
            "state": "answered", "visibility": "private", "provenance": "stated",
        },
        "dup": {
            "prompt": "job", "section": "misc", "level": 2,
            "answer_type": "narrative", "answer": "Product manager at Google",
            "state": "answered", "visibility": "private", "provenance": "inferred",
        },
        "grandchild": {
            "prompt": "detail", "section": "misc", "level": 3,
            "answer_type": "narrative", "answer": "since 2020",
            "parent": "dup", "state": "answered", "visibility": "private",
            "provenance": "stated",
        },
    }
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})
    res = store.merge_nodes(db, UID, "survivor", "dup")
    assert res["removed"] == "dup" and res["rehomed_children"] == 1
    overlay = store.load_overlay(db, UID)
    assert "dup" not in overlay
    assert overlay["grandchild"]["parent"] == "survivor"  # rehomed
    # the duplicate's answer is retired to the survivor's history, never dropped
    hist = overlay["survivor"].get("history") or []
    assert any(h.get("answer") == "Product manager at Google" for h in hist)


def test_merge_refuses_seed_node_as_duplicate():
    seed_id = next(iter(pg.seed().keys()))
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, {
        "e": {"prompt": "x", "section": "misc", "level": 2,
              "answer_type": "narrative", "answer": "x", "state": "answered",
              "visibility": "private", "provenance": "stated"},
    })})
    with pytest.raises(ValueError):
        store.merge_nodes(db, UID, "e", seed_id)


# --- resolution: link + keep ----------------------------------------------


def test_link_related_adds_two_way_related_links():
    nodes = {
        "a": {"prompt": "a", "section": "career", "level": 2,
              "answer_type": "narrative", "answer": "PM at Google",
              "state": "answered", "visibility": "private", "provenance": "stated"},
        "b": {"prompt": "b", "section": "hobbies", "level": 2,
              "answer_type": "narrative", "answer": "climb at Google gym",
              "state": "answered", "visibility": "private", "provenance": "stated"},
    }
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})
    assert store.link_related(db, UID, "a", "b", label="both about Google") is True
    overlay = store.load_overlay(db, UID)
    a_links = overlay["a"]["links"]
    b_links = overlay["b"]["links"]
    assert any(l["target"] == "b" and l["type"] == "related" for l in a_links)
    assert any(l["target"] == "a" and l["type"] == "related" for l in b_links)
    # idempotent
    assert store.link_related(db, UID, "a", "b") is False


def test_dedupe_dismiss_roundtrip():
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, {})})
    store.dedupe_dismiss(db, UID, "b", "a")
    assert ("a", "b") in store.dedupe_dismissed(db, UID)  # stored sorted


def test_dismissal_survives_overlay_replace():
    # merge_nodes / delete_nodes rewrite the overlay doc whole (merge=False); a
    # "keep both" decision must not be wiped by a later graph write.
    nodes = {
        "a": {"prompt": "a", "section": "misc", "level": 2, "answer_type": "narrative",
              "answer": "x", "state": "answered", "visibility": "private",
              "provenance": "stated"},
        "b": {"prompt": "b", "section": "misc", "level": 2, "answer_type": "narrative",
              "answer": "y", "state": "answered", "visibility": "private",
              "provenance": "stated"},
    }
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})
    store.dedupe_dismiss(db, UID, "a", "b")
    store.delete_nodes(db, UID, ["b"])  # rewrites the overlay doc whole
    assert ("a", "b") in store.dedupe_dismissed(db, UID)


# --- write-time prevention -------------------------------------------------


def test_write_time_prevention_collapses_exact_on_flag(monkeypatch):
    nodes = {
        "existing": {"prompt": "x", "section": "misc", "level": 1,
                     "answer_type": "narrative", "answer": "I love Thai food",
                     "state": "answered", "visibility": "private",
                     "provenance": "stated"},
    }
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})
    monkeypatch.setattr(
        config, "CONFIG",
        dataclasses.replace(config.CONFIG, node_dedupe_prevention=True),
    )
    # an exact restatement reuses the existing node instead of minting a new one
    nid = store.add_loose_node(db, UID, "i love thai food!")
    assert nid == "existing"
    assert len(store.load_overlay(db, UID)) == 1


def _identity_db(standard):
    """A FakeDb whose overlay holds the given standard identity answers (seed
    node ids), so effective() marks them ``standard``."""
    return FakeDb({**_profile(UID), **_overlay_doc(UID, dict(standard))})


def test_editor_import_does_not_mint_restatement_of_standard_fact():
    """Founder build 2488: the editor write-back minted
    ``emergent.editor.identity.*`` nodes that only restated a standard fact
    ("Ethnic and cultural origin: South Asian" beside the ethnic-origin row,
    "Age: 33", "Interested in: Women"). The gap: the standard bullet's id is a
    SEED id, so it never matched an editor-owned node and a duplicate was minted.
    The write path now drops any bullet that only restates a standard fact —
    merge-not-mint — while keeping genuinely new bullets."""
    db = _identity_db({
        "ethnic_cultural_origin": {"answer": "South Asian", "state": "answered"},
        "target_match_genders": {"answer": ["Women"], "state": "answered"},
        "gender_identity": {"answer": "Male", "state": "answered"},
    })
    bullets = [
        {"id": "ethnic_cultural_origin", "text": "South Asian", "visibility": "private"},
        {"id": "", "text": "Ethnic and cultural origin: South Asian", "visibility": "private"},
        {"id": "", "text": "Interested in: Women", "visibility": "public"},
        {"id": "", "text": "Gender: Male", "visibility": "public"},
        {"id": "", "text": "Grew up in Chennai", "visibility": "public"},  # a distinct fact
    ]
    result_ids = store.replace_section_bullets(db, UID, "identity", bullets)
    overlay = store.load_overlay(db, UID)
    # No editor node that restates a standard fact was minted.
    editor_nodes = [n for n in overlay if n.startswith("emergent.editor.identity.")]
    editor_texts = {str(overlay[n].get("answer")) for n in editor_nodes}
    assert editor_texts == {"Grew up in Chennai"}  # only the distinct bullet survived
    assert "Ethnic and cultural origin: South Asian" not in editor_texts
    assert "Interested in: Women" not in editor_texts
    # the standard seed nodes are untouched (the facts still live on them)
    assert overlay["ethnic_cultural_origin"]["answer"] == "South Asian"


def test_add_loose_node_reuses_standard_fact_instead_of_minting():
    """``remember`` / off-script facts route through ``add_loose_node``; a fact
    that restates a standard identity answer reuses the standard node (returns
    its id) rather than minting a second node — always on, no flag."""
    db = _identity_db({
        "ethnic_cultural_origin": {"answer": "South Asian", "state": "answered"},
    })
    before = len(store.load_overlay(db, UID))
    nid = store.add_loose_node(db, UID, "Ethnic and cultural origin: South Asian")
    assert nid == "ethnic_cultural_origin"  # reused the standard node
    assert len(store.load_overlay(db, UID)) == before  # nothing minted


def test_write_time_prevention_off_by_default_creates_node(monkeypatch):
    nodes = {
        "existing": {"prompt": "x", "section": "misc", "level": 1,
                     "answer_type": "narrative", "answer": "I love Thai food",
                     "state": "answered", "visibility": "private",
                     "provenance": "stated"},
    }
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})
    monkeypatch.setattr(
        config, "CONFIG",
        dataclasses.replace(config.CONFIG, node_dedupe_prevention=False),
    )
    nid = store.add_loose_node(db, UID, "i love thai food!")
    assert nid != "existing"
    assert len(store.load_overlay(db, UID)) == 2


# --- write-time CONFLICT raising (founder Nov 17, assessment part d) --------


def _stub_judge(monkeypatch, verdict):
    """Monkeypatch the LiveKit judge to a fixed reply (``verdict`` is the dict
    gemini.generate_json returns, or an Exception instance to simulate failure)."""
    calls = {"n": 0}

    async def _fake(*a, **k):
        calls["n"] += 1
        if isinstance(verdict, Exception):
            raise verdict
        return verdict

    monkeypatch.setattr(gemini, "generate_json", _fake)
    return calls


def test_candidates_for_text_same_topic_excludes_exact_and_unrelated():
    graph = {
        "job": _node("job", "career", 2, answer="I work at Google as a product manager"),
        "food": _node("food", "misc", 2, answer="I love Thai food"),
    }
    idx = index_mod.index_from_graph(graph)
    cands = crosscheck.candidates_for_text(
        idx, "I work at Amazon as a product manager now"
    )
    ids = [c.node_id for c in cands]
    assert "job" in ids  # same topic (work / product manager) surfaced
    assert "food" not in ids  # unrelated topic not surfaced
    # an EXACT restatement is a duplicate, never a conflict candidate
    assert crosscheck.candidates_for_text(
        idx, "I work at Google as a product manager"
    ) == []


def test_classify_conflict_returns_entry_on_verdict(monkeypatch):
    graph = {
        "job": _node("job", "career", 2, answer="I work at Google as a product manager"),
    }
    idx = index_mod.index_from_graph(graph)
    new = "I work at Amazon as a product manager now"
    cands = crosscheck.candidates_for_text(idx, new)
    _stub_judge(monkeypatch, {"conflict_i": 0})
    hit = asyncio.run(crosscheck.classify_conflict(new, cands))
    assert hit is not None and hit.node_id == "job"


def test_classify_conflict_none_when_no_conflict(monkeypatch):
    graph = {"job": _node("job", "career", 2, answer="I work at Google as a PM")}
    idx = index_mod.index_from_graph(graph)
    cands = crosscheck.candidates_for_text(idx, "I work at Google, love my team")
    _stub_judge(monkeypatch, {"conflict_i": None})
    assert asyncio.run(crosscheck.classify_conflict("x", cands)) is None


def test_classify_conflict_none_on_judge_failure(monkeypatch):
    graph = {"job": _node("job", "career", 2, answer="I work at Google as a PM")}
    idx = index_mod.index_from_graph(graph)
    cands = crosscheck.candidates_for_text(idx, "I work at Amazon as a product manager")
    _stub_judge(monkeypatch, RuntimeError("livekit 429"))
    # best-effort: a judge failure never blocks — no conflict, the write proceeds
    assert asyncio.run(crosscheck.classify_conflict("x", cands)) is None


def _conflict_db():
    nodes = {
        "job": {
            "prompt": "job", "section": "career", "level": 2,
            "answer_type": "narrative", "answer": "I work at Google as a product manager",
            "state": "answered", "visibility": "private", "provenance": "stated",
        },
    }
    return FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})


def _remember_fn(db):
    from skills import remember as remember_skill

    return remember_skill.SKILL.bind(
        db, UID, session_id="sess1", turn_index=3, turns=[]
    )


def test_remember_raises_conflict_and_does_not_write_second_node(monkeypatch):
    # The exact founder path (part d): a NEW fact in chat that contradicts an
    # existing node is RAISED IN CHAT and NOT stored as a second node.
    db = _conflict_db()
    monkeypatch.setattr(
        config, "CONFIG",
        dataclasses.replace(
            config.CONFIG, person_graph_reads=True, node_conflict_raise=True
        ),
    )
    _stub_judge(monkeypatch, {"conflict_i": 0})
    out = asyncio.run(_remember_fn(db)(highlight="I work at Amazon as a product manager now"))
    assert out.startswith("CONFLICT")
    assert "job" in out  # names the existing node for pg_resolve_conflict
    overlay = store.load_overlay(db, UID)
    assert list(overlay.keys()) == ["job"]  # no second, contradictory node written


def test_remember_writes_when_judge_finds_no_conflict(monkeypatch):
    db = _conflict_db()
    monkeypatch.setattr(
        config, "CONFIG",
        dataclasses.replace(
            config.CONFIG, person_graph_reads=True, node_conflict_raise=True
        ),
    )
    _stub_judge(monkeypatch, {"conflict_i": None})
    out = asyncio.run(_remember_fn(db)(highlight="I also mentor two junior PMs at Google"))
    assert out == "noted — added to your story"
    assert len(store.load_overlay(db, UID)) == 2  # non-conflicts still save


def test_remember_conflict_off_by_default_writes_without_judge(monkeypatch):
    db = _conflict_db()
    monkeypatch.setattr(
        config, "CONFIG",
        dataclasses.replace(
            config.CONFIG, person_graph_reads=True, node_conflict_raise=False
        ),
    )
    called = _stub_judge(monkeypatch, {"conflict_i": 0})
    out = asyncio.run(_remember_fn(db)(highlight="I work at Amazon as a product manager now"))
    assert out == "noted — added to your story"
    assert len(store.load_overlay(db, UID)) == 2
    assert called["n"] == 0  # flag off: no LiveKit call at all


def test_resolve_conflict_incoming_overwrites_and_retires_old():
    db = _conflict_db()
    from skills import node_dedupe

    resolve = node_dedupe._bind_resolve_conflict(db, UID)
    msg = resolve("job", "incoming", new_value="I work at Amazon as a product manager")
    assert "updated job" in msg
    overlay = store.load_overlay(db, UID)
    assert list(overlay.keys()) == ["job"]  # still exactly one node
    assert overlay["job"]["answer"] == "I work at Amazon as a product manager"
    hist = overlay["job"].get("history") or []
    assert any("Google" in str(h.get("answer")) for h in hist)  # old value kept


def test_resolve_conflict_existing_keeps_old_unchanged():
    db = _conflict_db()
    from skills import node_dedupe

    resolve = node_dedupe._bind_resolve_conflict(db, UID)
    msg = resolve("job", "existing")
    assert "kept your existing note" in msg
    overlay = store.load_overlay(db, UID)
    assert overlay["job"]["answer"] == "I work at Google as a product manager"
    assert not overlay["job"].get("history")  # nothing changed


# --- the semantic judge batches so a large candidate set never truncates -----


def test_judge_chunks_large_batch_so_a_reply_never_truncates(monkeypatch):
    """NOTE 252 (Daniel fixture, build 2493): _judge put all 68 candidate pairs
    in ONE generate_json call; the reply truncated (finish_reason=length) and the
    whole array failed to parse, losing every verdict and silently degrading the
    sweep to the lexical split. _judge must batch so each reply stays within
    budget and every pair is still judged, and no single call carries more than
    _JUDGE_BATCH pairs."""
    calls = []

    async def _fake(payload, system, **k):
        chunk = __import__("json").loads(payload)
        calls.append(len(chunk))
        return [{"i": it["i"], "verdict": "duplicate"} for it in chunk]

    monkeypatch.setattr(gemini, "generate_json", _fake)
    items = [{"i": n, "a": f"fact {n}", "b": f"fact {n}, reworded"} for n in range(60)]
    verdicts = asyncio.run(crosscheck._judge(items, uid="u"))
    assert verdicts is not None
    assert set(verdicts) == set(range(60))  # every pair judged across batches
    assert all(v == "duplicate" for v in verdicts.values())
    assert len(calls) > 1  # actually chunked, not one oversized call
    assert max(calls) <= crosscheck._JUDGE_BATCH


def test_judge_partial_batch_failure_keeps_the_other_batches(monkeypatch):
    """A single failing batch is skipped without discarding the verdicts the
    other batches returned (strictly better than the old all-or-nothing None)."""

    async def _fake(payload, system, **k):
        chunk = __import__("json").loads(payload)
        if chunk[0]["i"] == 0:  # fail only the first batch
            raise RuntimeError("livekit hiccup on first batch")
        return [{"i": it["i"], "verdict": "related"} for it in chunk]

    monkeypatch.setattr(gemini, "generate_json", _fake)
    items = [{"i": n, "a": f"x{n}", "b": f"y{n}"} for n in range(2 * crosscheck._JUDGE_BATCH)]
    verdicts = asyncio.run(crosscheck._judge(items, uid="u"))
    assert verdicts is not None
    assert 0 not in verdicts  # first batch lost
    assert crosscheck._JUDGE_BATCH in verdicts  # second batch kept


def test_judge_returns_none_when_every_batch_fails(monkeypatch):
    """Total failure still returns None so classify_pairs keeps the lexical
    report unchanged (the preserved best-effort contract)."""

    async def _fake(payload, system, **k):
        raise RuntimeError("livekit down")

    monkeypatch.setattr(gemini, "generate_json", _fake)
    items = [{"i": n, "a": f"x{n}", "b": f"y{n}"} for n in range(30)]
    assert asyncio.run(crosscheck._judge(items, uid="u")) is None
