"""NOTE 228: when the person-graph is authoritative, the `remember` tool writes
the fact to the GRAPH (a loose emergent node) — not the wiki — so chat facts land
in graph/main while the wiki is left untouched.

NOTE 227 stopped chats writing to the old store (the central `wiki_ingest.ingest`
gate) AND dropped `remember`; the low-level pg_* tools need a parent_id the model
never discovered, so facts landed in NEITHER store (NOTE 228 split-brain). The fix
keeps `remember` and redirects its binding to `person_graph_store.add_loose_node`.
"""

import asyncio
import dataclasses

import config
import person_graph as pg
import person_graph_render as render
import person_graph_store as store
import wiki_ingest
from config import CONFIG
from skills import remember as remember_skill
from transcript import ROLE_USER, Turn


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
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def _patch(monkeypatch, *, reads: bool):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=reads)
    )
    wiki_calls = []

    async def _fake_ingest(db, uid, session_id, turns, **kw):
        wiki_calls.append(uid)
        return 2

    monkeypatch.setattr(wiki_ingest, "ingest", _fake_ingest)
    return wiki_calls


# --- the loose-node store primitive -----------------------------------------


def test_add_loose_node_creates_a_parentless_misc_node():
    db = FakeDb()
    nid = store.add_loose_node(db, "u1", "Daniel has a mentor named Priya")
    ov = store.load_overlay(db, "u1")
    assert nid in ov
    node = ov[nid]
    assert node["section"] == "misc" and node["answer_type"] == "narrative"
    assert node["answer"] == "Daniel has a mentor named Priya"
    assert node.get("parent") in (None, "")  # stand-alone, no seed parent
    # It renders (by section, not by a parent tree).
    g = pg.effective_graph(store.load_overlay(db, "u1"))
    assert "Priya" in render.persona_prose(g, include_ayma_only=True)


# --- the remember tool routes to the graph when authoritative ---------------


def test_remember_writes_the_graph_not_the_wiki_when_authoritative(monkeypatch):
    wiki_calls = _patch(monkeypatch, reads=True)
    db = FakeDb()
    before = len(store.load_overlay(db, "u1"))
    fn = remember_skill.SKILL.bind(db, "u1", session_id="s1", turn_index=9, turns=[])
    reply = asyncio.run(fn(highlight="Daniel hikes Redwood Regional on weekends"))
    assert "noted" in reply.lower()
    # Graph grew by the fact node; the wiki was NOT written.
    after = store.load_overlay(db, "u1")
    assert len(after) == before + 1
    assert any("Redwood" in (n.get("answer") or "") for n in after.values())
    assert wiki_calls == []  # wiki untouched (§9.5)


def test_remember_falls_back_to_the_last_user_line(monkeypatch):
    _patch(monkeypatch, reads=True)
    db = FakeDb()
    turns = [Turn(ROLE_USER, "My mentor is Priya, she runs design at my company")]
    fn = remember_skill.SKILL.bind(db, "u1", session_id="s1", turn_index=9, turns=turns)
    asyncio.run(fn(highlight=""))  # no explicit highlight → use the last user line
    ov = store.load_overlay(db, "u1")
    assert any("Priya" in (n.get("answer") or "") for n in ov.values())


def test_remember_uses_the_wiki_path_when_flag_off(monkeypatch):
    wiki_calls = _patch(monkeypatch, reads=False)
    db = FakeDb()
    turns = [Turn(ROLE_USER, "I love rock climbing")]
    fn = remember_skill.SKILL.bind(db, "u1", session_id="s1", turn_index=9, turns=turns)
    asyncio.run(fn(highlight="loves rock climbing"))
    assert wiki_calls == ["u1"]            # legacy wiki ingest ran
    assert store.load_overlay(db, "u1") == {}  # no graph node written
