"""``generate_image`` — in-chat image generation (founder request 2026-09-26:
"create a caricature of myself" → "now render the image" got "I don't have the
tools to generate actual images here").

Same Gemini image model, moderation, storage upload and mutable ``result``
delivery sink as ``edit_photo`` (tests/test_photo_edit_skill.py) — plus the
generation-only pieces: no input photo required, an optional
``use_my_photo="yes"`` reference grounded in the user's latest chat photo, and
the identity gate that refuses to generate another real person's likeness.
Every Gemini/moderation/storage call is faked."""

import asyncio

import pytest

import face_match
import skills
import token_ledger
from skills import face_report as face_report_mod
from skills import generate_image


# ---------------------------------------------------------------- registration


def test_generate_image_is_always_in_the_text_tool_set():
    base = {d["name"] for d in skills.session_tool_declarations()}
    assert "generate_image" in base
    # ...including in every scoped chat variant (nothing removes it).
    scoped = {
        d["name"]
        for d in skills.session_tool_declarations(story=True, photo=True)
    }
    assert "generate_image" in scoped


def test_generate_image_is_not_in_the_voice_registry():
    # Voice (make_livekit_tools) pulls _REGISTRY + app_control; it has no
    # image-delivery surface, so the tool must stay out of it.
    assert "generate_image" not in {s.name for s in skills.all_skills()}
    assert "generate_image" not in {s.name for s in skills._REGISTRY}
    assert {s.name for s in skills._TEXT_ONLY_REGISTRY} == {"generate_image"}


def test_declaration_carries_the_guidance_lines():
    desc = generate_image.DECLARATION["description"]
    assert "use_my_photo" in desc
    # The other-member likeness rule lives here (the backend can't resolve a
    # name in a text prompt, the model can).
    assert "another real member" in desc
    props = generate_image.DECLARATION["parameters"]["properties"]
    assert set(props) == {"prompt", "style", "use_my_photo"}
    assert generate_image.DECLARATION["parameters"]["required"] == ["prompt"]


# ------------------------------------------------------------------ happy path


def _happy_fakes(monkeypatch, calls):
    async def fake_generate_image(prompt, *, image=None, uid=None, feature=""):
        calls["model"] = (prompt, image, uid, feature)
        return b"NEWBYTES", "image/png"

    async def fake_moderate(image_bytes, mime_type, **_kw):
        calls["moderate"] = (image_bytes, mime_type)
        return {"allowed": True, "reason": "", "categories": []}

    def fake_store(uid, image_bytes, mime_type):
        calls["store"] = (uid, image_bytes, mime_type)
        return ("ayma_generated/u9/gen.png", "https://cdn/gen.png")

    monkeypatch.setattr(generate_image.gemini, "generate_image", fake_generate_image)
    monkeypatch.setattr(generate_image.photo_moderation, "moderate", fake_moderate)
    monkeypatch.setattr(generate_image, "_store_generated_photo", fake_store)


def test_generate_calls_model_moderates_uploads_and_fills_result(monkeypatch):
    calls: dict = {}
    _happy_fakes(monkeypatch, calls)

    result: dict = {}
    fn = generate_image._bind(object(), "u9", result=result)
    out = asyncio.run(fn(prompt="a caricature of a chess-playing engineer"))

    assert out == "done — sent the image in the chat"
    assert calls["model"] == (
        "a caricature of a chess-playing engineer", None, "u9",
        token_ledger.FEATURE_IMAGE_GEN,
    )
    assert calls["moderate"] == (b"NEWBYTES", "image/png")
    assert calls["store"] == ("u9", b"NEWBYTES", "image/png")
    # Exactly the delivery contract edit_photo uses — main.py reads these two
    # keys off ctx.photo_edit_result for the reply's image_url + transcript.
    assert result == {
        "image_path": "ayma_generated/u9/gen.png",
        "image_url": "https://cdn/gen.png",
    }


def test_style_hint_is_folded_into_the_prompt(monkeypatch):
    calls: dict = {}
    _happy_fakes(monkeypatch, calls)

    fn = generate_image._bind(object(), "u9", result={})
    asyncio.run(fn(prompt="a caricature of me", style="pencil sketch"))

    prompt = calls["model"][0]
    assert "a caricature of me" in prompt
    assert "pencil sketch" in prompt


def test_empty_prompt_asks_for_one(monkeypatch):
    def _boom(*_a, **_kw):  # pragma: no cover
        raise AssertionError("model must not be called")

    monkeypatch.setattr(generate_image.gemini, "generate_image", _boom)
    fn = generate_image._bind(object(), "u9")
    assert "tell me" in asyncio.run(fn(prompt="  ")).lower()


def test_make_session_tool_fns_threads_the_image_result_sink(monkeypatch):
    """The actual wiring main.py relies on: ``image_result`` (the shared
    ``ctx.photo_edit_result`` sink) reaches the bound closure."""
    calls: dict = {}
    _happy_fakes(monkeypatch, calls)

    result: dict = {}
    fns = skills.make_session_tool_fns(object(), "u9", image_result=result)
    assert "generate_image" in fns

    out = asyncio.run(fns["generate_image"](prompt="a sunrise over Kochi"))

    assert out == "done — sent the image in the chat"
    assert result["image_url"] == "https://cdn/gen.png"


# --------------------------------------------------- use_my_photo reference


def test_use_my_photo_grounds_generation_in_the_latest_chat_photo(monkeypatch):
    calls: dict = {}
    _happy_fakes(monkeypatch, calls)
    monkeypatch.setattr(
        face_report_mod, "_latest_chat_image", lambda db, uid: "uploads/u9/x.jpg"
    )
    import media_embed

    monkeypatch.setattr(
        media_embed, "download_bytes", lambda path: (b"SELFIE", "image/jpeg")
    )
    monkeypatch.setattr(
        generate_image, "_classify_reference", lambda *a: "self"
    )

    fn = generate_image._bind(object(), "u9", result={})
    out = asyncio.run(fn(prompt="a caricature of me", use_my_photo="yes"))

    assert out == "done — sent the image in the chat"
    assert calls["model"][1] == (b"SELFIE", "image/jpeg")


def test_use_my_photo_with_no_recent_photo_asks_for_one(monkeypatch):
    def _boom(*_a, **_kw):  # pragma: no cover
        raise AssertionError("model must not be called")

    monkeypatch.setattr(generate_image.gemini, "generate_image", _boom)
    monkeypatch.setattr(face_report_mod, "_latest_chat_image", lambda db, uid: "")

    fn = generate_image._bind(object(), "u9", result={})
    out = asyncio.run(fn(prompt="a caricature of me", use_my_photo="yes"))
    assert out == generate_image._NO_REFERENCE


def test_use_my_photo_refuses_when_the_photo_is_someone_else(monkeypatch):
    """The other-member likeness gate: the reference photo is identity-checked
    with the same face-match the shared-photo verdict uses — confidently NOT
    the account holder → refuse, and never call the image model."""

    def _boom(*_a, **_kw):  # pragma: no cover
        raise AssertionError("model must not be called for someone else's face")

    monkeypatch.setattr(generate_image.gemini, "generate_image", _boom)
    monkeypatch.setattr(
        face_report_mod, "_latest_chat_image", lambda db, uid: "uploads/u9/x.jpg"
    )
    import media_embed

    monkeypatch.setattr(
        media_embed, "download_bytes", lambda path: (b"OTHER", "image/jpeg")
    )
    monkeypatch.setattr(
        generate_image, "_classify_reference", lambda *a: "not_self"
    )

    result: dict = {}
    fn = generate_image._bind(object(), "u9", result=result)
    out = asyncio.run(fn(prompt="a caricature of me", use_my_photo="yes"))

    assert out == generate_image._NOT_SELF
    assert result == {}


def test_classify_reference_uses_the_shared_face_match(monkeypatch):
    """Same mechanism as main._classify_shared_photo: the pairwise
    ``face_match.classify_photo`` check against the user's own reference
    photos; no references (or a failed check) → 'unknown' (permissive,
    matching face_report on the same photo)."""

    async def _not_self(*_a, **_k):
        return {"verdict": "not_self", "confidence": "high",
                "face_visible": True, "reason": "Different person."}

    monkeypatch.setattr(face_match, "classify_photo", _not_self)
    assert generate_image._classify_reference(object(), "u9", b"X", "image/jpeg") == "not_self"

    async def _unknown(*_a, **_k):
        return {"verdict": "unknown", "confidence": "low",
                "face_visible": True,
                "reason": "No reference photos for this account"}

    monkeypatch.setattr(face_match, "classify_photo", _unknown)
    assert generate_image._classify_reference(object(), "u9", b"X", "image/jpeg") == "unknown"

    async def _boom(*_a, **_k):
        raise RuntimeError("vision model call failed")

    monkeypatch.setattr(face_match, "classify_photo", _boom)
    assert generate_image._classify_reference(object(), "u9", b"X", "image/jpeg") == "unknown"


# --------------------------------------------------------------- failure modes


def test_out_of_credits_falls_back_to_the_shared_copy(monkeypatch):
    async def fake_generate_image(*_a, **_kw):
        raise token_ledger.TokenCapExceeded("out of credits")

    monkeypatch.setattr(generate_image.gemini, "generate_image", fake_generate_image)
    fn = generate_image._bind(object(), "u9")
    out = asyncio.run(fn(prompt="a caricature of me"))
    assert out == token_ledger.out_of_credits_message(token_ledger.CONTEXT_IMAGE_GEN)


def test_model_failure_falls_back_to_text(monkeypatch):
    async def fake_generate_image(*_a, **_kw):
        raise RuntimeError("safety refusal")

    monkeypatch.setattr(generate_image.gemini, "generate_image", fake_generate_image)
    result: dict = {}
    fn = generate_image._bind(object(), "u9", result=result)
    out = asyncio.run(fn(prompt="a caricature of me"))
    assert "couldn't generate" in out.lower()
    assert "safety refusal" in out
    assert result == {}


def test_moderation_rejection_is_never_uploaded(monkeypatch):
    async def fake_generate_image(*_a, **_kw):
        return b"NEWBYTES", "image/png"

    async def fake_moderate(*_a, **_kw):
        return {"allowed": False, "reason": "explicit", "categories": ["nudity"]}

    def fake_store(*_a, **_kw):  # pragma: no cover
        raise AssertionError("a rejected image must never be uploaded")

    monkeypatch.setattr(generate_image.gemini, "generate_image", fake_generate_image)
    monkeypatch.setattr(generate_image.photo_moderation, "moderate", fake_moderate)
    monkeypatch.setattr(generate_image, "_store_generated_photo", fake_store)

    result: dict = {}
    fn = generate_image._bind(object(), "u9", result=result)
    out = asyncio.run(fn(prompt="something dodgy"))
    assert "safety check" in out.lower()
    assert result == {}


# --------------------------------------------------------------------- billing


def test_gemini_generate_image_is_restored_and_returns_bytes(monkeypatch):
    """Image generation is restored (founder decision 2026-11-08): the
    pre-kill contract is back — an ``ok`` outcome from the Gemini-direct path
    returns (bytes, mime), and the prompt/uid/feature reach image_gen."""
    import gemini as gemini_mod
    import image_gen

    seen = {}

    async def fake_generate(prompt, *, image=None, uid=None, feature="misc"):
        seen["call"] = (prompt, image, uid, feature)
        return image_gen.ImageOutcome(
            image_gen.STATUS_OK, image_bytes=b"IMG", mime="image/png"
        )

    monkeypatch.setattr(gemini_mod.token_ledger, "check", lambda uid: None)
    monkeypatch.setattr(image_gen, "generate", fake_generate)

    out = asyncio.run(
        gemini_mod.generate_image(
            "a caricature", uid="u9", feature=token_ledger.FEATURE_IMAGE_GEN
        )
    )
    assert out == (b"IMG", "image/png")
    assert seen["call"] == (
        "a caricature", None, "u9", token_ledger.FEATURE_IMAGE_GEN
    )


def test_gemini_generate_image_surfaces_honest_failure_not_a_stub(monkeypatch):
    """A non-ok outcome raises RuntimeError carrying the honest, user-safe
    message from the typed outcome — the skill catches it and relays it as a
    plain chat turn (test_model_failure_falls_back_to_text)."""
    import gemini as gemini_mod
    import image_gen

    async def fake_generate(prompt, *, image=None, uid=None, feature="misc"):
        return image_gen.ImageOutcome(
            image_gen.STATUS_ERROR, message="safety refusal: no dice"
        )

    monkeypatch.setattr(gemini_mod.token_ledger, "check", lambda uid: None)
    monkeypatch.setattr(image_gen, "generate", fake_generate)
    with pytest.raises(RuntimeError) as exc:
        asyncio.run(
            gemini_mod.generate_image("x", uid="u9", feature="image_gen")
        )
    assert "safety refusal: no dice" in str(exc.value)


def test_gemini_generate_image_out_of_credits_never_reaches_provider(monkeypatch):
    """The per-user credit gate runs first: an out-of-credits user raises
    TokenCapExceeded before image_gen is touched, so the daily cap is never
    consumed and no provider call is made."""
    import gemini as gemini_mod
    import image_gen

    def _cap(uid):
        raise token_ledger.TokenCapExceeded("out of credits")

    async def _never(*_a, **_k):  # pragma: no cover - must not be reached
        raise AssertionError("image_gen must not run for a broke user")

    monkeypatch.setattr(gemini_mod.token_ledger, "check", _cap)
    monkeypatch.setattr(image_gen, "generate", _never)
    with pytest.raises(token_ledger.TokenCapExceeded):
        asyncio.run(gemini_mod.generate_image("x", uid="u9"))


def test_cost_usd_for_image_gen_prices_image_output():
    """Same model as photo_edit: input $0.30/M, image output $30/M tokens."""
    cost = token_ledger.cost_usd_for(
        token_ledger.FEATURE_IMAGE_GEN, 1_000_000, 1_000_000,
        model="gemini-2.5-flash-image", image_output_tokens=1_000_000,
    )
    assert cost == pytest.approx(0.30 + 30.0)
