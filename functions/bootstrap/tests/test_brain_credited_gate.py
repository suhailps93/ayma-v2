"""Credited-brains gate (founder order 2026-11-07).

A deploy that is not credited for a direct-API brain must never offer it in
a selection list or serve it: only Gemini runs on the funded LiveKit
Inference credits, while Meta Muse Spark bills the Meta Model API directly
(the $150 hackathon credits do not cover it) and the open-weights brain
bills its Modal endpoint. Staging pins ``BRAIN_CREDITED_PROVIDERS=gemini``;
the production default credits all three, so prod behaviour is unchanged.
"""

import dataclasses

import llm_provider
import schema
import voice_catalog as vc
from config import CONFIG
from llm_provider import (
    CAP_JSON,
    CAP_TEXT,
    GeminiProvider,
    MetaProvider,
    available_brains,
    brain_is_credited,
    get_user_brain_provider,
)

STAGING_CREDITED = ("gemini",)
FULL_CREDITED = ("gemini", "meta", "open-weights")
OW_URL = "https://modal.example/v1"
OW_MODEL = "meta-llama/Llama-3.1-8B-Instruct"


def _llm_config(monkeypatch, credited):
    monkeypatch.setattr(
        llm_provider,
        "CONFIG",
        dataclasses.replace(CONFIG, brain_credited_providers=credited),
    )


def _vc_config(monkeypatch, credited, **over):
    monkeypatch.setattr(
        vc,
        "CONFIG",
        dataclasses.replace(vc.CONFIG, brain_credited_providers=credited, **over),
    )
    vc.clear_cache()


def _saved_brain(monkeypatch, value):
    monkeypatch.setattr(llm_provider, "read_brain_pref", lambda uid: value)


# --- the predicate ---------------------------------------------------------


def test_brain_is_credited_full_set(monkeypatch):
    _llm_config(monkeypatch, FULL_CREDITED)
    assert brain_is_credited("gemini") is True
    assert brain_is_credited("meta") is True
    assert brain_is_credited("open-weights") is True
    assert brain_is_credited("banana") is False


def test_brain_is_credited_staging_set(monkeypatch):
    _llm_config(monkeypatch, STAGING_CREDITED)
    assert brain_is_credited("gemini") is True
    assert brain_is_credited("meta") is False
    assert brain_is_credited("open-weights") is False


def test_gemini_is_credited_even_with_an_empty_set(monkeypatch):
    # Gemini is the funded default and the fallback of last resort: a deploy
    # can never gate itself out of its own fallback.
    _llm_config(monkeypatch, ())
    assert brain_is_credited("gemini") is True
    assert brain_is_credited("meta") is False


# --- text Brain picker (llm_provider.available_brains) ---------------------


def test_available_brains_default_lists_gemini_then_meta(monkeypatch):
    _llm_config(monkeypatch, FULL_CREDITED)
    assert [b["id"] for b in available_brains()] == ["gemini", "meta"]


def test_available_brains_staging_lists_gemini_only(monkeypatch):
    _llm_config(monkeypatch, STAGING_CREDITED)
    brains = available_brains()
    assert [b["id"] for b in brains] == ["gemini"]
    assert all(b["id"] != "meta" for b in brains)


# --- saved-preference resolution (get_user_brain_provider) ------------------


def test_saved_meta_brain_falls_back_to_gemini_on_staging(monkeypatch):
    _llm_config(monkeypatch, STAGING_CREDITED)
    _saved_brain(monkeypatch, "meta")
    # Never Meta, never an error — Gemini serves every capability.
    assert isinstance(
        get_user_brain_provider("u1", "chat", needs=CAP_TEXT), GeminiProvider
    )
    assert isinstance(
        get_user_brain_provider("u1", "matching", needs=CAP_JSON), GeminiProvider
    )
    assert isinstance(get_user_brain_provider("u1", "chat"), GeminiProvider)


def test_saved_meta_brain_honoured_when_credited(monkeypatch):
    _llm_config(monkeypatch, FULL_CREDITED)
    _saved_brain(monkeypatch, "meta")
    assert isinstance(
        get_user_brain_provider("u1", "matching", needs=CAP_JSON), MetaProvider
    )


def test_saved_gemini_brain_unaffected_by_the_gate(monkeypatch):
    _llm_config(monkeypatch, STAGING_CREDITED)
    _saved_brain(monkeypatch, "gemini")
    assert isinstance(
        get_user_brain_provider("u1", "chat", needs=CAP_TEXT), GeminiProvider
    )


# --- voice catalog lists -----------------------------------------------------


def test_voice_catalog_staging_hides_meta_and_open_weights(monkeypatch):
    _vc_config(
        monkeypatch,
        STAGING_CREDITED,
        open_weights_api_base_url=OW_URL,
        open_weights_model=OW_MODEL,
    )
    brains = vc.catalog()["brains"]
    ids = [b["id"] for b in brains]
    assert vc.BRAIN_META not in ids
    assert vc.BRAIN_OPEN_WEIGHTS not in ids
    # The LiveKit Inference brains stay listed.
    assert "google/gemini-3.8-flash" in ids
    assert vc.is_valid_brain(vc.BRAIN_META) is False
    assert vc.is_valid_brain(vc.BRAIN_OPEN_WEIGHTS) is False


def test_voice_catalog_default_lists_meta_and_open_weights(monkeypatch):
    _vc_config(
        monkeypatch,
        FULL_CREDITED,
        open_weights_api_base_url=OW_URL,
        open_weights_model=OW_MODEL,
    )
    ids = [b["id"] for b in vc.catalog()["brains"]]
    assert vc.BRAIN_META in ids
    assert vc.BRAIN_OPEN_WEIGHTS in ids
    assert vc.is_valid_brain(vc.BRAIN_META) is True


def test_voice_catalog_staging_hides_meta_route_extra_brains(monkeypatch):
    _vc_config(
        monkeypatch,
        STAGING_CREDITED,
        voice_cascade_extra_brains=("custom-meta|meta|meta/model-x",),
    )
    ids = [b["id"] for b in vc.catalog()["brains"]]
    assert "custom-meta" not in ids


# --- voice routing / resolution ----------------------------------------------


def test_brain_route_meta_gated(monkeypatch):
    _vc_config(monkeypatch, STAGING_CREDITED)
    assert vc.brain_route(vc.BRAIN_META) is None
    _vc_config(monkeypatch, FULL_CREDITED)
    assert vc.brain_route(vc.BRAIN_META) == (
        vc.ROUTE_META,
        vc.CONFIG.meta_chat_model,
    )


def test_brain_route_open_weights_gated(monkeypatch):
    _vc_config(
        monkeypatch,
        STAGING_CREDITED,
        open_weights_api_base_url=OW_URL,
        open_weights_model=OW_MODEL,
    )
    assert vc.brain_route(vc.BRAIN_OPEN_WEIGHTS) is None
    _vc_config(
        monkeypatch,
        FULL_CREDITED,
        open_weights_api_base_url=OW_URL,
        open_weights_model=OW_MODEL,
    )
    assert vc.brain_route(vc.BRAIN_OPEN_WEIGHTS) == (vc.ROUTE_OPEN_WEIGHTS, OW_MODEL)


def test_resolved_cascade_brain_saved_meta_maps_to_gemini_on_staging(monkeypatch):
    _vc_config(monkeypatch, STAGING_CREDITED)
    prof = {schema.PF_AYMA_BRAIN_MODEL: "meta"}
    assert vc.resolved_cascade_brain(prof).startswith("google/")
    # A legacy stored Meta cascade brain is overridden the same way.
    legacy = {schema.PF_AYMA_CASCADE_BRAIN: vc.BRAIN_META}
    assert vc.resolved_cascade_brain(legacy).startswith("google/")


def test_resolved_cascade_brain_saved_meta_unchanged_when_credited(monkeypatch):
    _vc_config(monkeypatch, FULL_CREDITED)
    prof = {schema.PF_AYMA_BRAIN_MODEL: "meta"}
    assert vc.resolved_cascade_brain(prof) == vc.BRAIN_META


def test_default_selection_staging_preselects_gemini_brain(monkeypatch):
    _vc_config(monkeypatch, STAGING_CREDITED)
    d = vc.default_selection()
    assert d["brain_id"].startswith("google/")
    assert d["brain_id"] != vc.BRAIN_META


def test_default_selection_default_config_unchanged(monkeypatch):
    _vc_config(monkeypatch, FULL_CREDITED)
    d = vc.default_selection()
    assert d["brain_id"] == vc.BRAIN_META


# --- /brain/preference endpoint ----------------------------------------------

import main  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from firebase_admin import auth as firebase_auth  # noqa: E402

client = TestClient(main.app)


class _ProfileDoc:
    def __init__(self, stored=None):
        self.stored = dict(stored or {})
        self.written = {}

    def get(self):
        doc = self

        class _S:
            exists = True

            def to_dict(self_):
                return dict(doc.stored)

        return _S()

    def set(self, payload, merge=False):
        self.written.update(payload)
        self.stored.update(payload)


def _endpoint_setup(monkeypatch, credited):
    _llm_config(monkeypatch, credited)
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "me"}
    )
    doc = _ProfileDoc()
    monkeypatch.setattr(main.schema, "profile_doc", lambda _db, _uid: doc)
    monkeypatch.setattr(main, "get_db", lambda: object())
    return doc, {"Authorization": "Bearer token"}


def test_endpoint_staging_lists_gemini_only(monkeypatch):
    _doc, headers = _endpoint_setup(monkeypatch, STAGING_CREDITED)
    resp = client.get("/brain/preference", headers=headers)
    assert resp.status_code == 200
    assert [b["id"] for b in resp.json()["brains"]] == ["gemini"]


def test_endpoint_staging_rejects_a_meta_save(monkeypatch):
    doc, headers = _endpoint_setup(monkeypatch, STAGING_CREDITED)
    resp = client.post("/brain/preference", json={"brain": "meta"}, headers=headers)
    assert resp.status_code == 422
    assert schema.PF_AYMA_BRAIN_MODEL not in doc.written


def test_endpoint_default_still_accepts_meta(monkeypatch):
    doc, headers = _endpoint_setup(monkeypatch, FULL_CREDITED)
    resp = client.post("/brain/preference", json={"brain": "meta"}, headers=headers)
    assert resp.status_code == 200
    assert doc.written[schema.PF_AYMA_BRAIN_MODEL] == "meta"
