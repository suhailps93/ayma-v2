"""ONE BRAIN (founder, 2026-11-06): the Models screen's single Brain
selection drives BOTH the text path and the voice/agent path.

Covered:
* the vendor -> cascade-brain mapping and the read-time resolution that
  supersedes any stored per-user voice brain;
* ``GET /voice/engines`` and ``main._voice_engine_seed`` (what the agent
  receives) resolving the SAME brain the text path reads
  (``llm_provider.read_brain_pref`` / ``get_user_brain_provider``);
* ``POST /brain/preference`` keeping the stored cascade brain in sync;
* ``POST /voice/preference`` never resurrecting a superseded voice brain;
* ``POST /models/preference`` — the screen's ONE save — persisting brain +
  voice stack in one action, and marking the reconnect announcement when
  asked to reconnect.
"""

import llm_provider
import main
import schema
import voice_catalog
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer <redacted>"}


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


def _patch_db(monkeypatch, doc):
    monkeypatch.setattr(main.schema, "profile_doc", lambda _db, _uid: doc)
    monkeypatch.setattr(main, "get_db", lambda: object())


def setup_function(_):
    voice_catalog.clear_cache()


# --- the mapping + resolution (voice_catalog) -------------------------------

def test_mapping_meta_and_gemini():
    assert voice_catalog.cascade_brain_for_unified("meta") == voice_catalog.BRAIN_META
    gem = voice_catalog.cascade_brain_for_unified("gemini")
    assert gem.startswith("google/")
    assert voice_catalog.is_valid_brain(gem)
    assert voice_catalog.cascade_brain_for_unified("banana") == ""


def test_resolved_cascade_brain_unified_supersedes_stored_voice_brain():
    prof = {
        schema.PF_AYMA_BRAIN_MODEL: "meta",
        schema.PF_AYMA_CASCADE_BRAIN: "google/gemini-3.7-flash",
    }
    assert voice_catalog.resolved_cascade_brain(prof) == voice_catalog.BRAIN_META
    prof = {
        schema.PF_AYMA_BRAIN_MODEL: "gemini",
        schema.PF_AYMA_CASCADE_BRAIN: "meta-muse-spark",
    }
    assert voice_catalog.resolved_cascade_brain(prof).startswith("google/")


def test_resolved_cascade_brain_legacy_honoured_only_without_unified():
    prof = {schema.PF_AYMA_CASCADE_BRAIN: "google/gemini-3.7-flash"}
    assert voice_catalog.resolved_cascade_brain(prof) == "google/gemini-3.7-flash"
    assert voice_catalog.resolved_cascade_brain({}, "fallback-x") == "fallback-x"


# --- (a) text path and voice/agent path resolve the SAME brain --------------

def _both_paths(monkeypatch, prof):
    """(text provider name, agent seed brain_id) for one saved profile."""
    doc = _ProfileDoc(prof)
    _patch_db(monkeypatch, doc)
    # Text path: llm_provider reads the same profile field via its own db
    # handle; point it at the same fake doc.
    monkeypatch.setattr(llm_provider, "read_brain_pref", lambda uid: prof.get(schema.PF_AYMA_BRAIN_MODEL, ""))
    text_provider = llm_provider.get_user_brain_provider("me", "chat").name
    seed = main._voice_engine_seed("me")
    engines = client.get("/voice/engines", headers=_auth(monkeypatch)).json()
    return text_provider, seed["brain_id"], engines["current"]["brain_id"]


def test_both_paths_serve_meta_when_brain_is_meta(monkeypatch):
    prof = {
        schema.PF_AYMA_BRAIN_MODEL: "meta",
        schema.PF_AYMA_VOICE_MODE: "cascade",
        # A stale, divergent stored voice brain: superseded, never served.
        schema.PF_AYMA_CASCADE_BRAIN: "google/gemini-3.7-flash",
        schema.PF_AYMA_CASCADE_STT: "deepgram/nova-3",
        schema.PF_AYMA_CASCADE_TTS: "inworld/inworld-tts-1",
    }
    text_provider, seed_brain, engines_brain = _both_paths(monkeypatch, prof)
    assert text_provider == "meta"
    assert seed_brain == voice_catalog.BRAIN_META
    assert engines_brain == voice_catalog.BRAIN_META


def test_both_paths_serve_gemini_when_brain_is_gemini(monkeypatch):
    prof = {
        schema.PF_AYMA_BRAIN_MODEL: "gemini",
        schema.PF_AYMA_VOICE_MODE: "cascade",
        schema.PF_AYMA_CASCADE_BRAIN: "meta-muse-spark",
        schema.PF_AYMA_CASCADE_STT: "deepgram/nova-3",
        schema.PF_AYMA_CASCADE_TTS: "inworld/inworld-tts-1",
    }
    text_provider, seed_brain, engines_brain = _both_paths(monkeypatch, prof)
    assert text_provider == "gemini"
    assert seed_brain.startswith("google/")
    assert engines_brain == seed_brain


# --- write-sync on the individual endpoints ---------------------------------

def test_brain_preference_post_syncs_cascade_brain(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/brain/preference", json={"brain": "meta"}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    assert doc.written[schema.PF_AYMA_BRAIN_MODEL] == "meta"
    assert doc.written[schema.PF_AYMA_CASCADE_BRAIN] == voice_catalog.BRAIN_META


def test_voice_preference_post_cannot_resurrect_superseded_brain(monkeypatch):
    doc = _ProfileDoc({schema.PF_AYMA_BRAIN_MODEL: "gemini"})
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/voice/preference",
        headers=_auth(monkeypatch),
        json={
            "mode": "cascade",
            "brain_id": "meta-muse-spark",
            "stt_id": "deepgram/nova-3",
            "tts_id": "inworld/inworld-tts-1",
            "voice_id": "Ashley",
            "language_code": "",
        },
    )
    assert resp.status_code == 200
    # The saved ONE brain (Gemini) wins over the submitted legacy brain id.
    assert doc.written[schema.PF_AYMA_CASCADE_BRAIN].startswith("google/")


# --- (c) the ONE save: POST /models/preference -------------------------------

def test_models_preference_one_save_persists_brain_and_stack(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/models/preference",
        headers=_auth(monkeypatch),
        json={
            "brain": "meta",
            "mode": "cascade",
            "stt_id": "cartesia/ink-2",
            "tts_id": "inworld/inworld-tts-1",
            "voice_id": "Ashley",
            "language_code": "",
            "accent": "",
        },
    )
    # cartesia/ink-2 is only in the catalog when Cartesia is enabled; in the
    # offline test env it may be gated out, so accept either the cartesia
    # save or a 422 that names the STT - but with deepgram it must succeed.
    if resp.status_code != 200:
        resp = client.post(
            "/models/preference",
            headers=_auth(monkeypatch),
            json={
                "brain": "meta",
                "mode": "cascade",
                "stt_id": "deepgram/nova-3",
                "tts_id": "inworld/inworld-tts-1",
                "voice_id": "Ashley",
                "language_code": "",
                "accent": "",
            },
        )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["ok"] is True and body["brain"] == "meta"
    assert doc.written[schema.PF_AYMA_BRAIN_MODEL] == "meta"
    assert doc.written[schema.PF_AYMA_CASCADE_BRAIN] == voice_catalog.BRAIN_META
    assert doc.written[schema.PF_AYMA_VOICE_MODE] == "cascade"
    assert doc.written[schema.PF_AYMA_CASCADE_TTS] == "inworld/inworld-tts-1"
    assert doc.written[schema.PF_AYMA_TTS_VOICE] == "Ashley"


def test_models_preference_gemini_brain_maps_to_google_cascade(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/models/preference",
        headers=_auth(monkeypatch),
        json={
            "brain": "gemini",
            "mode": "cascade",
            "stt_id": "deepgram/nova-3",
            "tts_id": "inworld/inworld-tts-1",
            "voice_id": "Ashley",
            "language_code": "",
        },
    )
    assert resp.status_code == 200, resp.text
    assert doc.written[schema.PF_AYMA_BRAIN_MODEL] == "gemini"
    assert doc.written[schema.PF_AYMA_CASCADE_BRAIN].startswith("google/")


def test_models_preference_realtime_keeps_brain_synced(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/models/preference",
        headers=_auth(monkeypatch),
        json={
            "brain": "meta",
            "mode": "realtime",
            "realtime_model_id": "gemini-live",
            "voice_id": "Aoede",
            "language_code": "",
        },
    )
    assert resp.status_code == 200, resp.text
    assert doc.written[schema.PF_AYMA_BRAIN_MODEL] == "meta"
    assert doc.written[schema.PF_AYMA_CASCADE_BRAIN] == voice_catalog.BRAIN_META


def test_models_preference_reconnect_marks_announcement(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/models/preference",
        headers=_auth(monkeypatch),
        json={
            "brain": "meta",
            "mode": "cascade",
            "stt_id": "deepgram/nova-3",
            "tts_id": "inworld/inworld-tts-1",
            "voice_id": "Ashley",
            "language_code": "",
            "reconnect": True,
        },
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["reconnect"] is True
    from skills import set_model_stack
    assert doc.stored.get(set_model_stack._PF_RECONNECT_PENDING) is True
    assert doc.stored.get(set_model_stack._PF_RECONNECT_AT)


def test_models_preference_rejects_unknown_brain(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/models/preference",
        headers=_auth(monkeypatch),
        json={"brain": "banana", "mode": "cascade", "stt_id": "deepgram/nova-3",
              "tts_id": "inworld/inworld-tts-1"},
    )
    assert resp.status_code == 422
    assert schema.PF_AYMA_BRAIN_MODEL not in doc.written
