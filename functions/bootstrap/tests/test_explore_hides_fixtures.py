import pytest
import config
import explore as ex
from fake_firestore import FakeDb


def _seed(rows):
    """rows: list of (uid, name, user_doc). Returns a FakeDb seed dict with
    both the top-level user doc and a profile/main carrying the name."""
    seed = {}
    for uid, name, user_doc in rows:
        seed[("users", uid)] = dict(user_doc)
        seed[("users", uid, "profile", "main")] = {"name": name}
    return FakeDb(seed)


ROWS = [
    ("viewer", "Viewer Vee", {}),
    ("demo-test1", "Daniel Reyes", {}),
    ("demo-test2", "Sofia Marino", {}),
    ("demo-test3", "Priya Nair", {}),
    ("demo-edge-nophoto", "Nadia Okafor", {"exclude_from_explore": True}),
    ("demo-edge-ageover", "Teresa Alvarez", {"exclude_from_explore": True}),
    ("demo-edge-orient", "Robin Shaw", {}),
    ("demo_practice_maya", "Maya", {}),
]


def test_normal_user_explore_hides_fixtures_keeps_curated_demo():
    db = _seed(ROWS)
    cards = ex.explore(db, "viewer", {})
    uids = {c["uid"] for c in cards}
    names = " ".join(c.get("name", "") for c in cards)
    assert "demo-edge-nophoto" not in uids
    assert "demo-edge-ageover" not in uids
    assert "demo-edge-orient" not in uids
    assert "demo-test1" in uids
    assert "demo-test2" in uids
    assert "demo-test3" in uids
    assert "demo_practice_maya" not in uids
    assert "viewer" in uids
    assert "Nadia" not in names
    assert "Teresa" not in names
    assert "Robin" not in names
    assert "Maya" not in names
    assert "Daniel" in names
    assert "Sofia" in names
    assert "Priya" in names


def test_e2e_bypass_viewer_sees_fixtures():
    if "demo-test1" not in config.CONFIG.explore_fixture_bypass_uids:
        pytest.skip("demo-test1 not in bypass set")
    db = _seed(ROWS)
    cards = ex.explore(db, "demo-test1", {})
    uids = {c["uid"] for c in cards}
    assert "demo-edge-nophoto" in uids and "demo-edge-ageover" in uids and "demo-edge-orient" in uids
