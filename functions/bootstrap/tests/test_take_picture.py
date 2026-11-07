"""``take_picture`` (founder feedback item 12, Nov 6, 2026): Ayma confirms
front-or-back BEFORE capturing, then the client captures, the photo lands
in the chat, and the ack's vision reaction is relayed. The fake Firestore
harness is shared with ``test_app_control`` (the established cross-test
import pattern in this suite)."""

from __future__ import annotations

import pytest

from skills import app_control, take_picture
from test_app_control import _ACK, _PENDING, _Db, _run


class _PictureAckStore(dict):
    """A healthy client for a capture: acks the pending command with the
    capture outcome (image_path + the vision reaction as ``result``), or
    with a failure ``reason`` when ``ok`` is False."""

    def __init__(self, *a, ok=True, reason="", library_saved=True, **k):
        super().__init__(*a, **k)
        self._ok = ok
        self._reason = reason
        self._library_saved = library_saved

    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        if key == _PENDING and isinstance(value, dict) and value.get("id"):
            ack = {"id": value["id"], "ok": self._ok}
            if self._ok:
                ack["image_path"] = "uploads/me/chat_123.jpg"
                ack["result"] = "You look great — that jacket really suits you."
                ack["library_saved"] = self._library_saved
            elif self._reason:
                ack["reason"] = self._reason
            super().__setitem__(_ACK, ack)


def test_no_camera_asks_front_or_back_and_queues_nothing():
    db = _Db(_PictureAckStore())
    out = _run(app_control._bind_take_picture(db, "me")())
    assert "Front or back camera?" in out
    assert _PENDING not in db.store  # confirm first: nothing captured yet


def test_unrecognised_camera_still_asks_and_queues_nothing():
    db = _Db(_PictureAckStore())
    out = _run(app_control._bind_take_picture(db, "me")("side"))
    assert "Front or back camera?" in out
    assert _PENDING not in db.store


def test_front_camera_queues_capture_and_relays_the_vision_reaction():
    db = _Db(_PictureAckStore())
    out = _run(app_control._bind_take_picture(db, "me")("front"))
    cmd = db.store[_PENDING]
    assert cmd["action"] == "take_picture" and cmd["camera"] == "front"
    assert out.startswith("Done: took a picture with the front camera")
    assert "uploads/me/chat_123.jpg" in out
    # The reaction Ayma already gave in chat (from actually seeing the
    # photo through the /chat vision path) is relayed for consistency.
    assert "that jacket really suits you" in out
    # Founder spec: both destinations — the library copy is reported too.
    assert "also saved to their photo library" in out


def test_library_save_off_is_reported_not_hidden():
    db = _Db(_PictureAckStore(library_saved=False))
    out = _run(app_control._bind_take_picture(db, "me")("front"))
    assert "did NOT get saved to their photo library" in out
    assert "that jacket really suits you" in out  # vision reaction relayed


def test_back_camera_is_passed_through():
    db = _Db(_PictureAckStore())
    out = _run(app_control._bind_take_picture(db, "me")("back"))
    assert db.store[_PENDING]["camera"] == "back"
    assert "back camera" in out


def test_cancelled_capture_reports_no_picture():
    db = _Db(_PictureAckStore(ok=False, reason="cancelled"))
    out = _run(app_control._bind_take_picture(db, "me")("front"))
    assert "no picture was taken" in out


def test_permission_denied_capture_reports_the_permission_line():
    db = _Db(_PictureAckStore(ok=False, reason="camera_unavailable"))
    out = _run(app_control._bind_take_picture(db, "me")("front"))
    assert "camera permission" in out


def test_no_ack_is_an_honest_failure_never_a_success(monkeypatch):
    monkeypatch.setattr(take_picture, "_TAKE_PICTURE_ACK_TIMEOUT_SECONDS", 0.05)
    monkeypatch.setattr(app_control, "_ACK_POLL_SECONDS", 0.01)
    db = _Db()  # no client — nothing ever acks
    out = _run(app_control._bind_take_picture(db, "me")("front"))
    assert "did NOT take a picture" in out


def test_take_picture_is_a_command_tool_in_voice_and_text():
    assert "take_picture" in {s.name for s in app_control.COMMAND_SKILLS}
    assert "take_picture" in {s.name for s in app_control.VOICE_SKILLS}


def test_registry_names_the_take_picture_media_action():
    import app_registry

    actions = {a["key"]: a for a in app_registry.media_actions()}
    assert actions["take_picture"]["via"] == "take_picture"
