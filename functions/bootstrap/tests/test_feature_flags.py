"""feature_flags.py: resolution order, legacy docs, validation, branch defaults,
scripts/flags.py set / rollback, the admin read-only view and the
fail-loudly (no Google fallback) behaviour."""

from __future__ import annotations

import asyncio
import dataclasses
import importlib.util
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import auth
import feature_flags as ff
import gemini
import inference_llm
import main
from config import CONFIG

from fake_firestore import FakeDb

client = TestClient(main.app)
_REAL_READ_DOCS = ff._read_docs  # the autouse fixture stubs ff._read_docs

def _branch(monkeypatch):
    """Undo the suite-wide baseline: use the real config.py defaults."""
    import config

    monkeypatch.setattr(ff, "CONFIG", config.CONFIG)


def _docs(monkeypatch, doc):
    monkeypatch.setattr(ff, "_read_docs", lambda: doc)
    ff.reset_cache()


def test_branch_defaults_have_every_feature_on(monkeypatch):
    _branch(monkeypatch)
    for name in ("llm_route_json", "llm_route_vision", "llm_route_chat"):
        assert ff.get(name) == "inference"
    assert ff.get("voice_provider") == "inference"
    assert ff.get("llm_percent_voice") == 100
    assert ff.get("llm_allowlist_voice") == ()
    assert ff.get("llm_fallback_to_google") is False
    for name in ("maps_grounding", "deepdive_public_profiles", "vertex_ai_search", "sentry"):
        assert ff.enabled(name) is True
    assert ff.get("deepdive_blocked_regions") == ("illinois", "texas", "eu")
    assert ff.get("vertex_ai_search_daily_cap") == 300
    assert {v["source"] for v in ff.snapshot().values()} == {"default"}


def test_every_registered_flag_is_in_the_seed_file_and_documented(monkeypatch):
    _branch(monkeypatch)
    root = Path(__file__).resolve().parents[3]
    seed = json.loads((root / "scripts" / "feature_flags.seed.json").read_text())
    assert set(seed) == set(ff.REGISTRY)
    doc = (root / "docs" / "FEATURE_FLAGS.md").read_text()
    for name in ff.REGISTRY:
        assert f"`{name}`" in doc, name
    for name, value in seed.items():  # the seed is valid and equals the defaults
        coerced = ff._coerce(ff.REGISTRY[name], value)
        assert coerced == ff.get(name) or list(coerced) == list(ff.get(name))


def test_env_beats_firestore_beats_default(monkeypatch):
    _branch(monkeypatch)
    _docs(monkeypatch, {"maps_grounding": False, "llm_route_chat": "vertex"})
    assert ff.resolve("maps_grounding") == (False, "firestore")
    assert ff.resolve("llm_route_json") == ("inference", "default")
    monkeypatch.setenv("FLAG_MAPS_GROUNDING", "true")
    assert ff.resolve("maps_grounding") == (True, "env")


def test_invalid_values_fall_through_to_the_next_layer(monkeypatch):
    _branch(monkeypatch)
    _docs(monkeypatch, {"llm_route_json": "bogus", "llm_percent_json": 500,
                        "maps_grounding": "yes", "llm_allowlist_voice": "founder"})
    monkeypatch.setenv("FLAG_SENTRY", "maybe")
    assert ff.get("llm_route_json") == "inference"
    assert ff.get("llm_percent_json") == 100
    assert ff.get("maps_grounding") is True
    assert ff.get("llm_allowlist_voice") == ()
    assert ff.get("sentry") is True


def test_legacy_docs_are_a_fallback_below_the_new_doc(monkeypatch):
    _branch(monkeypatch)
    legacy = ff._legacy_routing({
        "chat": {"provider": "vertex", "percent": 10},
        "voice": {"provider": "google", "allowlist": ["u1"]},
        "fallback": True,
    })
    assert legacy == {
        "llm_route_chat": "vertex", "llm_percent_chat": 10,
        "voice_provider": "google", "llm_allowlist_voice": ["u1"],
        "llm_fallback_to_google": True,
    }
    _docs(monkeypatch, {**legacy, "llm_route_chat": "inference", "sentry": False})
    assert ff.get("llm_route_chat") == "inference"  # new doc wins
    assert ff.get("llm_percent_chat") == 10  # legacy still applies
    assert ff.get("voice_provider") == "google"
    assert ff.get("llm_allowlist_voice") == ("u1",)
    assert ff.get("llm_fallback_to_google") is True
    assert ff.get("sentry") is False


def test_read_docs_merges_legacy_docs_under_the_new_doc(monkeypatch):
    store = FakeDb({
        ("config", "llm_routing"): {"json": "vertex", "fallback": True},
        ("app_config", "sentry"): {"enabled": False},
        ("config", "feature_flags"): {"llm_route_json": "inference", "_history": []},
    })

    class _Db:
        def collection(self, c):
            outer = store.collection(c)
            return type("C", (), {"document": lambda _s, d: _Doc(outer.document(d))})()

    class _Doc:
        def __init__(self, ref):
            self._ref = ref

        def get(self, timeout=None):
            return self._ref.get()

    import db

    monkeypatch.setattr(db, "get_db", lambda: _Db())
    merged = _REAL_READ_DOCS()
    assert merged == {
        "llm_route_json": "inference", "llm_fallback_to_google": True, "sentry": False,
    }


def test_unreadable_firestore_keeps_last_good_doc(monkeypatch):
    _docs(monkeypatch, {"maps_grounding": False})
    assert ff.get("maps_grounding") is False
    ff._cache["at"] = -1e9

    def boom():
        raise RuntimeError("down")

    monkeypatch.setattr(ff, "_read_docs", boom)
    assert ff.get("maps_grounding") is False


def test_flag_doc_is_cached_for_a_minute(monkeypatch):
    calls = []

    def read():
        calls.append(1)
        return {}

    monkeypatch.setattr(ff, "_read_docs", read)
    ff.reset_cache()
    ff.get("sentry")
    ff.get("maps_grounding")
    assert len(calls) == 1


# --- scripts/flags.py ------------------------------------------------------


def _script():
    path = Path(__file__).resolve().parents[3] / "scripts" / "flags.py"
    spec = importlib.util.spec_from_file_location("flags_script", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_set_records_history_and_rollback_restores_previous_values():
    script = _script()
    db = FakeDb()
    script.apply(db, script.parse_assignments(["maps_grounding=false", "sentry=false"]), by="t")
    ref = db.collection("config").document("feature_flags")
    doc = ref.get().to_dict()
    assert doc["maps_grounding"] is False and doc["sentry"] is False
    assert doc["_history"][-1]["before"] == {}
    assert db.collection("app_config").document("sentry").get().to_dict() == {"enabled": False}

    script.apply(db, script.parse_assignments(["maps_grounding=true"]), by="t")
    assert ref.get().to_dict()["maps_grounding"] is True
    script.rollback(db)
    assert ref.get().to_dict()["maps_grounding"] is False
    script.rollback(db)
    final = ref.get().to_dict()
    assert "maps_grounding" not in final and final["_history"] == []
    assert script.rollback(db) is None


def test_script_rejects_unknown_flags_and_bad_values():
    script = _script()
    with pytest.raises(SystemExit):
        script.parse_assignments(["nope=true"])
    with pytest.raises(SystemExit):
        script.parse_assignments(["llm_route_json=bogus"])
    with pytest.raises(SystemExit):
        script.validate_values({"llm_percent_chat": 900})
    assert script.parse_assignments(["deepdive_blocked_regions=Illinois, eu"]) == {
        "deepdive_blocked_regions": ["illinois", "eu"]
    }


# --- admin view ------------------------------------------------------------


def test_admin_feature_flags_view_is_password_gated_and_lists_every_flag(monkeypatch):
    monkeypatch.setattr(
        auth, "CONFIG", dataclasses.replace(CONFIG, admin_password="pw-123")
    )
    assert client.get("/admin/feature-flags").status_code == 403
    r = client.get("/admin/feature-flags", headers={"X-Admin-Password": "pw-123"})
    assert r.status_code == 200
    assert set(r.json()["flags"]) == set(ff.REGISTRY)
    assert "Feature flags" in client.get("/admin").text


# --- no silent Google fallback --------------------------------------------


def test_inference_failure_surfaces_loudly_when_google_fallback_is_off(monkeypatch, caplog):
    _branch(monkeypatch)
    monkeypatch.setattr(gemini, "CONFIG", ff.CONFIG)
    monkeypatch.setattr(inference_llm, "CONFIG", ff.CONFIG)

    async def boom(**kw):
        raise RuntimeError("gateway 503")

    async def must_not_run(*a, **k):
        raise AssertionError("fell back to Google")

    monkeypatch.setattr(inference_llm, "complete", boom)
    monkeypatch.setattr(gemini, "_generate", must_not_run)
    with caplog.at_level("ERROR"):
        with pytest.raises(RuntimeError, match="gateway 503"):
            asyncio.run(gemini.generate_json("c", "s", None, enforce_cap=False))
        with pytest.raises(RuntimeError, match="gateway 503"):
            asyncio.run(_drain(gemini.generate_reply_events("hi", system_prompt="p")))
    assert "Google fallback is" in caplog.text


async def _drain(gen):
    async for _ in gen:
        pass
