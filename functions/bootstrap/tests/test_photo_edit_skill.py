"""delete_photo — Ayma can remove the in-focus "Chat about it" photo herself
when asked, instead of just explaining how to do it manually (§ founder bug:
"you do it" -> "I don't have the controls...").

Also ``edit_photo`` (founder request 2026-09-16: "If it's easy enough to call
Gemini image edit models let's do it") — calls the Gemini image-edit model on
the resolved photo bytes, moderates the result, uploads it, and hands the
generated image back through the mutable ``result`` sink so ``main.py`` can
attach it to the chat reply. Every Gemini/moderation/storage call is mocked;
the one real end-to-end feasibility call was manual verification only (see
the model id + region documented in ``config.py``'s LOCKED MODELS block)."""

import asyncio

import photo_notes
import skills
import token_ledger
from skills import photo_edit


def test_delete_photo_is_registered_and_exposed_with_the_photo_flag():
    names = {s.name for s in photo_edit.SKILLS}
    assert {"update_photo_note", "delete_photo", "edit_photo"} <= names

    base = {d["name"] for d in skills.session_tool_declarations()}
    withphoto = {d["name"] for d in skills.session_tool_declarations(photo=True)}
    assert withphoto - base == {"update_photo_note", "delete_photo", "edit_photo"}


def test_delete_photo_calls_hide_photo_with_uid_url_and_source(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        photo_notes, "hide_photo",
        lambda db, uid, url, *, source="": seen.update(
            db=db, uid=uid, url=url, source=source
        ),
    )
    sentinel = object()
    fn = skills.make_session_tool_fns(
        sentinel, "u9",
        photo_ctx={"url": "https://x/p.jpg", "source": "profile"},
    )["delete_photo"]

    out = fn()

    assert out == "done — removed that photo"
    assert seen == {
        "db": sentinel, "uid": "u9", "url": "https://x/p.jpg", "source": "profile",
    }


def test_delete_photo_with_no_photo_in_focus_does_not_error(monkeypatch):
    def _boom(*_a, **_kw):  # pragma: no cover
        raise AssertionError("hide_photo should not be called")

    monkeypatch.setattr(photo_notes, "hide_photo", _boom)
    fn = photo_edit._bind_delete(object(), "u9", url="", source="profile")
    assert fn() == "no photo in focus"


def test_photo_edit_context_mentions_she_can_delete_it():
    import main

    url = "https://x/p.jpg"
    attached = main._photo_edit_context(url, "profile", attached=True)
    not_attached = main._photo_edit_context(url, "profile", attached=False)
    for text in (attached, not_attached):
        assert "delete_photo" in text
        assert "you CAN do that yourself" in text


def test_photo_edit_context_attached_also_mentions_edit_photo():
    import main

    attached = main._photo_edit_context("https://x/p.jpg", "chat", attached=True)
    not_attached = main._photo_edit_context(
        "https://x/p.jpg", "chat", attached=False
    )
    assert "edit_photo" in attached
    # Ayma can't call it without the photo actually attached this turn.
    assert "edit_photo" not in not_attached


def test_attached_photo_edit_context_mentions_edit_photo_with_no_url():
    # A photo dropped straight into the main chat (§ founder report: "make
    # him a wolf" got "I can't actually edit or generate photos") has no
    # `photo_url`/Your Story origin at all — this is the prompt fragment that
    # tells Ayma she can still call `edit_photo` on it.
    import main

    text = main._attached_photo_edit_context()
    assert "edit_photo" in text
    assert "you CAN generate a real edited image" in text


def test_edit_photo_works_with_no_url_for_a_freshly_attached_photo(monkeypatch):
    async def fake_edit_image(img_bytes, mime, instruction, *, uid, feature):
        return b"NEWBYTES", "image/png"

    async def fake_moderate(image_bytes, mime_type):
        return {"allowed": True, "reason": "", "categories": []}

    def fake_store(uid, image_bytes, mime_type):
        return ("ayma_generated/u9/abc.png", "https://cdn/abc.png")

    monkeypatch.setattr(photo_edit.gemini, "edit_image", fake_edit_image)
    monkeypatch.setattr(photo_edit.photo_moderation, "moderate", fake_moderate)
    monkeypatch.setattr(photo_edit, "_store_generated_photo", fake_store)

    result: dict = {}
    fn = photo_edit._bind_edit(
        object(), "u9",
        url="", source="chat",
        image=(b"ORIGBYTES", "image/jpeg"),
        result=result,
    )

    out = asyncio.run(fn(instruction="make him a wolf"))

    assert out == "done — sent the edited photo in the chat"
    assert result["image_url"] == "https://cdn/abc.png"


def test_edit_photo_calls_model_moderates_uploads_and_fills_result(monkeypatch):
    calls = {}

    async def fake_edit_image(img_bytes, mime, instruction, *, uid, feature):
        calls["edit_image"] = (img_bytes, mime, instruction, uid, feature)
        return b"NEWBYTES", "image/png"

    async def fake_moderate(image_bytes, mime_type):
        calls["moderate"] = (image_bytes, mime_type)
        return {"allowed": True, "reason": "", "categories": []}

    def fake_store(uid, image_bytes, mime_type):
        calls["store"] = (uid, image_bytes, mime_type)
        return ("ayma_generated/u9/abc.png", "https://cdn/abc.png")

    monkeypatch.setattr(photo_edit.gemini, "edit_image", fake_edit_image)
    monkeypatch.setattr(photo_edit.photo_moderation, "moderate", fake_moderate)
    monkeypatch.setattr(photo_edit, "_store_generated_photo", fake_store)

    result: dict = {}
    fn = photo_edit._bind_edit(
        object(), "u9",
        url="https://x/p.jpg", source="chat",
        image=(b"ORIGBYTES", "image/jpeg"),
        result=result,
    )

    out = asyncio.run(fn(instruction="make this a studio photo"))

    assert out == "done — sent the edited photo in the chat"
    assert calls["edit_image"] == (
        b"ORIGBYTES", "image/jpeg", "make this a studio photo",
        "u9", token_ledger.FEATURE_PHOTO_EDIT,
    )
    assert calls["moderate"] == (b"NEWBYTES", "image/png")
    assert calls["store"] == ("u9", b"NEWBYTES", "image/png")
    assert result == {
        "image_path": "ayma_generated/u9/abc.png",
        "image_url": "https://cdn/abc.png",
    }


def test_edit_photo_with_no_image_falls_back_to_text():
    # No `photo_notes` lookup happens inside edit_photo — unlike
    # update_photo_note/delete_photo, it only ever needs the image bytes, so
    # an empty `url` (a freshly attached chat photo, not an existing
    # profile/story photo) must not be treated as "no photo in focus".
    fn = photo_edit._bind_edit(object(), "u9", url="", source="chat", image=None)
    out = asyncio.run(fn(instruction="do it"))
    assert "can't" in out.lower()


def test_edit_photo_with_no_visible_image_falls_back_to_text():
    fn = photo_edit._bind_edit(
        object(), "u9", url="https://x/p.jpg", source="chat", image=None,
    )
    out = asyncio.run(fn(instruction="make this a studio photo"))
    assert "can't" in out.lower()


def test_edit_photo_empty_instruction_asks_for_one():
    fn = photo_edit._bind_edit(
        object(), "u9", url="https://x/p.jpg", source="chat",
        image=(b"ORIGBYTES", "image/jpeg"),
    )
    assert "tell me" in asyncio.run(fn(instruction="  ")).lower()


def test_edit_photo_out_of_credits_falls_back_to_text(monkeypatch):
    async def fake_edit_image(*_a, **_kw):
        raise token_ledger.TokenCapExceeded("out of credits")

    monkeypatch.setattr(photo_edit.gemini, "edit_image", fake_edit_image)
    fn = photo_edit._bind_edit(
        object(), "u9", url="https://x/p.jpg", source="chat",
        image=(b"ORIGBYTES", "image/jpeg"),
    )
    out = asyncio.run(fn(instruction="make this a studio photo"))
    assert "out of credits" in out.lower()


def test_edit_photo_model_failure_falls_back_to_text_advice(monkeypatch):
    """A content-policy refusal / transient error must not crash the chat
    turn — Ayma should say so plainly and let the model's own next turn fall
    back to text-only advice (§ handle failure gracefully)."""

    async def fake_edit_image(*_a, **_kw):
        raise RuntimeError("safety refusal: can't edit real faces")

    monkeypatch.setattr(photo_edit.gemini, "edit_image", fake_edit_image)
    result: dict = {}
    fn = photo_edit._bind_edit(
        object(), "u9", url="https://x/p.jpg", source="chat",
        image=(b"ORIGBYTES", "image/jpeg"), result=result,
    )

    out = asyncio.run(fn(instruction="make this a studio photo"))

    assert "couldn't generate" in out.lower()
    assert "safety refusal" in out
    assert result == {}


def test_edit_photo_moderation_rejection_falls_back_to_text(monkeypatch):
    async def fake_edit_image(*_a, **_kw):
        return b"NEWBYTES", "image/png"

    async def fake_moderate(*_a, **_kw):
        return {"allowed": False, "reason": "explicit", "categories": ["nudity"]}

    def fake_store(*_a, **_kw):  # pragma: no cover
        raise AssertionError("a rejected image must never be uploaded")

    monkeypatch.setattr(photo_edit.gemini, "edit_image", fake_edit_image)
    monkeypatch.setattr(photo_edit.photo_moderation, "moderate", fake_moderate)
    monkeypatch.setattr(photo_edit, "_store_generated_photo", fake_store)

    result: dict = {}
    fn = photo_edit._bind_edit(
        object(), "u9", url="https://x/p.jpg", source="chat",
        image=(b"ORIGBYTES", "image/jpeg"), result=result,
    )

    out = asyncio.run(fn(instruction="make this a studio photo"))

    assert "safety check" in out.lower()
    assert result == {}


def test_make_session_tool_fns_threads_image_and_result_into_edit_photo(
    monkeypatch,
):
    """Integration check on the actual wiring ``main.py`` relies on: the
    ``photo_ctx`` dict's ``image``/``result`` keys reach the bound
    ``edit_photo`` closure, unlike ``delete_photo``/``update_photo_note``
    which ignore them."""

    async def fake_edit_image(img_bytes, mime, instruction, *, uid, feature):
        return b"NEWBYTES", "image/png"

    monkeypatch.setattr(photo_edit.gemini, "edit_image", fake_edit_image)
    monkeypatch.setattr(
        photo_edit.photo_moderation, "moderate",
        lambda *_a, **_kw: _allowed(),
    )
    monkeypatch.setattr(
        photo_edit, "_store_generated_photo",
        lambda *_a, **_kw: ("ayma_generated/u9/x.png", "https://cdn/x.png"),
    )

    result: dict = {}
    fns = skills.make_session_tool_fns(
        object(), "u9",
        photo_ctx={
            "url": "https://x/p.jpg", "source": "chat",
            "image": (b"ORIGBYTES", "image/jpeg"),
            "result": result,
        },
    )
    assert set(fns) >= {"update_photo_note", "delete_photo", "edit_photo"}

    out = asyncio.run(fns["edit_photo"](instruction="make this a studio photo"))

    assert out == "done — sent the edited photo in the chat"
    assert result["image_url"] == "https://cdn/x.png"


async def _allowed():
    return {"allowed": True, "reason": "", "categories": []}
