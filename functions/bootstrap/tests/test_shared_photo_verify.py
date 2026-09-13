"""A photo the user shares in chat is face-checked against their own profile
photos, and the verdict is threaded into the system prompt so Ayma doesn't
answer "how do I look?" about a stranger."""

import gemini
import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

from prompt import compose_system_prompt, load_persona

client = TestClient(app := main.app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid"}
    )
    return {"Authorization": "Bearer valid"}


def _capture_prompt(monkeypatch) -> dict:
    seen: dict = {}

    async def _fake(_message, system_prompt=None, **_kw):
        seen["prompt"] = system_prompt
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _fake)
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)
    monkeypatch.setattr(
        main.media_embed, "download_bytes",
        lambda _p: (b"JPEGBYTES", "image/jpeg"),
    )
    return seen


def _post_with_image(monkeypatch):
    return client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "how do I look today?",
            "image_path": "uploads/test-uid/chat_1.jpg",
        },
    )


def test_matching_face_gets_the_self_note(monkeypatch):
    seen = _capture_prompt(monkeypatch)
    monkeypatch.setattr(
        main.deep_dive_images, "_reference_embeddings",
        lambda _db, _uid: [[1.0, 0.0]],
    )
    monkeypatch.setattr(
        main.media_embed, "embed_image_bytes", lambda *_a, **_k: [1.0, 0.0]
    )
    resp = _post_with_image(monkeypatch)
    assert resp.status_code == 200
    assert "Shared photo:" in seen["prompt"]
    assert "looks like them" in seen["prompt"]


def test_far_face_gets_the_not_self_note(monkeypatch):
    seen = _capture_prompt(monkeypatch)
    monkeypatch.setattr(
        main.deep_dive_images, "_reference_embeddings",
        lambda _db, _uid: [[1.0, 0.0]],
    )
    monkeypatch.setattr(
        main.media_embed, "embed_image_bytes", lambda *_a, **_k: [0.0, 1.0]
    )
    resp = _post_with_image(monkeypatch)
    assert resp.status_code == 200
    assert "does NOT look like the account holder" in seen["prompt"]
    assert "ask who's in the picture" in seen["prompt"]


def test_borderline_similarity_gets_the_unknown_note(monkeypatch):
    seen = _capture_prompt(monkeypatch)
    monkeypatch.setattr(
        main.deep_dive_images, "_reference_embeddings",
        lambda _db, _uid: [[1.0, 0.0]],
    )
    # cosine == 0.5 — under _VERIFY_THRESHOLD (0.55) but inside the not_self
    # margin (0.55 - 0.08), so it's unverifiable rather than a rejection.
    monkeypatch.setattr(
        main.media_embed, "embed_image_bytes",
        lambda *_a, **_k: [0.5, 0.8660254],
    )
    resp = _post_with_image(monkeypatch)
    assert resp.status_code == 200
    assert "can't verify whether the photo" in seen["prompt"]


def test_no_reference_photos_gets_the_unknown_note(monkeypatch):
    seen = _capture_prompt(monkeypatch)
    monkeypatch.setattr(
        main.deep_dive_images, "_reference_embeddings", lambda _db, _uid: []
    )

    def _should_not_run(*_a, **_k):  # pragma: no cover
        raise AssertionError("no refs — should not bother embedding")

    monkeypatch.setattr(main.media_embed, "embed_image_bytes", _should_not_run)
    resp = _post_with_image(monkeypatch)
    assert resp.status_code == 200
    assert "can't verify whether the photo" in seen["prompt"]


def test_embed_failure_is_best_effort_unknown(monkeypatch):
    seen = _capture_prompt(monkeypatch)
    monkeypatch.setattr(
        main.deep_dive_images, "_reference_embeddings",
        lambda _db, _uid: [[1.0, 0.0]],
    )

    def _boom(*_a, **_k):
        raise RuntimeError("Vertex embed 503")

    monkeypatch.setattr(main.media_embed, "embed_image_bytes", _boom)
    resp = _post_with_image(monkeypatch)
    assert resp.status_code == 200
    assert "can't verify whether the photo" in seen["prompt"]


def test_no_image_no_shared_photo_line(monkeypatch):
    seen = _capture_prompt(monkeypatch)
    resp = client.post(
        "/chat", headers=_auth(monkeypatch), json={"message": "hi"}
    )
    assert resp.status_code == 200
    assert "Shared photo:" not in seen["prompt"]


def _capture_set_context(monkeypatch) -> list:
    """Patch `photo_notes.set_context` (as imported inside
    `main._persist_shared_photo_verdict`) and `public_profile._photo_url` so
    the persistence call site can be exercised without Firestore/Storage."""
    calls: list = []
    import photo_notes
    import public_profile

    def _fake_set_context(_db, uid, url, *, context=None, is_user=None):
        calls.append({"uid": uid, "url": url, "is_user": is_user})
        return {}

    monkeypatch.setattr(photo_notes, "set_context", _fake_set_context)
    monkeypatch.setattr(
        public_profile, "_photo_url",
        lambda path: f"https://cdn.example/{path}",
    )
    return calls


def test_a_confident_self_verdict_persists_and_overwrites_the_gallery_note(
    monkeypatch,
):
    seen = _capture_prompt(monkeypatch)
    calls = _capture_set_context(monkeypatch)
    monkeypatch.setattr(
        main.deep_dive_images, "_reference_embeddings",
        lambda _db, _uid: [[1.0, 0.0]],
    )
    monkeypatch.setattr(
        main.media_embed, "embed_image_bytes", lambda *_a, **_k: [1.0, 0.0]
    )
    resp = _post_with_image(monkeypatch)
    assert resp.status_code == 200
    assert "looks like them" in seen["prompt"]
    assert len(calls) == 1
    assert calls[0]["uid"] == "test-uid"
    assert calls[0]["url"] == "https://cdn.example/uploads/test-uid/chat_1.jpg"
    assert calls[0]["is_user"] == "yes"


def test_a_confident_not_self_verdict_persists_as_no(monkeypatch):
    seen = _capture_prompt(monkeypatch)
    calls = _capture_set_context(monkeypatch)
    monkeypatch.setattr(
        main.deep_dive_images, "_reference_embeddings",
        lambda _db, _uid: [[1.0, 0.0]],
    )
    monkeypatch.setattr(
        main.media_embed, "embed_image_bytes", lambda *_a, **_k: [0.0, 1.0]
    )
    resp = _post_with_image(monkeypatch)
    assert resp.status_code == 200
    assert "does NOT look like the account holder" in seen["prompt"]
    assert len(calls) == 1
    assert calls[0]["is_user"] == "no"


def test_an_unknown_verdict_never_persists_anything(monkeypatch):
    """No reference to compare against yet, or a borderline similarity — must
    not destroy an existing cached verdict with "I don't know"."""
    seen = _capture_prompt(monkeypatch)
    calls = _capture_set_context(monkeypatch)
    monkeypatch.setattr(
        main.deep_dive_images, "_reference_embeddings", lambda _db, _uid: []
    )
    resp = _post_with_image(monkeypatch)
    assert resp.status_code == 200
    assert "can't verify whether the photo" in seen["prompt"]
    assert calls == []


def test_compose_system_prompt_renders_shared_photo_note():
    note = "The photo the user just shared looks like them."
    out = compose_system_prompt(shared_photo_note=note)
    assert load_persona() in out
    assert "Shared photo: " + note in out


def test_blank_shared_photo_note_adds_nothing():
    assert compose_system_prompt(shared_photo_note="   ") == \
        compose_system_prompt()
