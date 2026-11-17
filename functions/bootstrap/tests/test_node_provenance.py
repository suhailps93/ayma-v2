"""Every node carries a SOURCE, stamped at write time (founder Nov 17).

A node created from a conversation carries the conversation (session) id, the
message id, and a timestamp; a web node carries its link. Stamped on the
creation paths; no backfill.
"""

import person_graph as pg
import person_graph_store as store
import person_graph_tree as tree


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


def test_add_loose_node_stamps_the_chat_source():
    db = FakeDb()
    nid = store.add_loose_node(
        db, "u1", "I grew up in Lisbon",
        source_kind="chat", source_ref="sess-42", source_message_id="7",
    )
    n = store.load_overlay(db, "u1")[nid]
    assert n["source_kind"] == "chat"
    assert n["source_ref"] == "sess-42"
    assert n["source_message_id"] == "7"
    assert n["source_created_at"]  # timestamped


def test_source_survives_effective_and_the_tree():
    db = FakeDb()
    nid = store.add_loose_node(
        db, "u1", "Loves jazz",
        source_kind="chat", source_ref="sess-9", source_message_id="3",
    )
    g = store.effective(db, "u1")
    assert g[nid].source_ref == "sess-9"
    assert g[nid].source_message_id == "3"
    # the node tree carries the source to the client
    t = tree.node_tree(g, surface="story")
    node = next(
        n for s in t["sections"] for n in s["nodes"] if n["id"] == nid
    )
    assert node["source_kind"] == "chat"
    assert node["source_ref"] == "sess-9"
    assert node["source_message_id"] == "3"


def test_upsert_fact_node_stamps_source():
    db = FakeDb()
    store.upsert_fact_node(
        db, "u1", "emergent.skill.web_findings", "Found online: a profile",
        source_kind="web", source_ref="https://example.com/jane",
    )
    n = store.load_overlay(db, "u1")["emergent.skill.web_findings"]
    assert n["source_kind"] == "web"
    assert n["source_ref"] == "https://example.com/jane"


def test_no_source_leaves_the_fields_unset():
    db = FakeDb()
    nid = store.add_loose_node(db, "u1", "A sourceless legacy-style fact")
    n = store.load_overlay(db, "u1")[nid]
    # Older/sourceless nodes are fine — no empty source keys forced on them.
    assert "source_kind" not in n
    assert "source_created_at" not in n


def test_remember_tool_stamps_the_conversation(monkeypatch):
    import asyncio

    import skills.remember as remember
    from config import CONFIG
    import dataclasses
    import config as config_mod

    monkeypatch.setattr(
        config_mod, "CONFIG",
        dataclasses.replace(CONFIG, person_graph_reads=True),
    )
    db = FakeDb()
    fn = remember._bind(db, "u1", session_id="sess-live", turn_index=5, turns=[])
    asyncio.run(fn(highlight="I run marathons"))

    nodes = store.load_overlay(db, "u1")
    saved = [n for n in nodes.values() if n.get("answer") == "I run marathons"]
    assert saved, "remember did not persist the fact"
    assert saved[0]["source_kind"] == "chat"
    assert saved[0]["source_ref"] == "sess-live"
    assert saved[0]["source_message_id"] == "5"


# --- the five call sites the sweep delta flagged as sourceless (now fixed) ---
def _graph_reads_on(monkeypatch):
    import dataclasses

    import config

    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(config.CONFIG, person_graph_reads=True)
    )


def test_steering_rule_node_carries_a_source(monkeypatch):
    import steering_ops

    _graph_reads_on(monkeypatch)
    db = FakeDb()
    steering_ops.add_rule(db, "u1", "Never call me dude")
    n = store.load_overlay(db, "u1")[steering_ops._GRAPH_NODE_ID]
    assert n["source_kind"] == "steering"
    assert n["source_ref"] == "user_directive"


def test_skill_memory_node_carries_a_source():
    import skill_memory

    db = FakeDb()
    skill_memory._graph_upsert_skill(db, "u1", "values", "Family first.")
    n = store.load_overlay(db, "u1")[skill_memory._skill_node_id("values")]
    assert n["source_kind"] == "skill_memory"
    assert n["source_ref"] == "values"


def test_pg_add_node_tool_stamps_the_agent_source():
    from skills import person_graph_tools

    db = FakeDb()
    fn = person_graph_tools._bind_add_node(db, "u1")
    out = fn("date_of_birth", "a note", answer="I was born at sunrise")
    assert out.startswith("added node")
    nid = out.split()[-1]
    n = store.load_overlay(db, "u1")[nid]
    assert n["source_kind"] == "chat"
    assert n["source_ref"] == "agent_tool"


def test_set_profile_field_stamps_the_chat_source(monkeypatch):
    from skills import set_profile_field

    _graph_reads_on(monkeypatch)
    db = FakeDb()
    fn = set_profile_field._bind(db, "u1", session_id="sess-77", turn_index=4)
    fn("last_name", "Reyes")
    n = store.load_overlay(db, "u1")["emergent.profile.last_name"]
    assert n["source_kind"] == "chat"
    assert n["source_ref"] == "sess-77"
    assert n["source_message_id"] == "4"
