import asyncio

import gemini
import photo_attrs


def test_schema_and_fields():
    fields = photo_attrs.attribute_fields()
    assert "hair_color" in fields and "glasses" in fields
    schema = photo_attrs._response_schema()
    assert schema["properties"]["glasses"]["enum"] == ["yes", "no", "unknown"]


def test_extract_returns_all_fields(monkeypatch):
    async def _fake(contents, system_prompt, response_schema=None, image=None):
        assert image == (b"IMG", "image/png")
        return {"hair_color": "brown", "glasses": "yes"}

    monkeypatch.setattr(gemini, "generate_json", _fake)
    out = asyncio.run(photo_attrs.extract_attributes(b"IMG", "image/png"))
    assert set(out) == set(photo_attrs.attribute_fields())
    assert out["hair_color"] == "brown"
    assert out["eye_color"] == "unknown"  # absent -> unknown


def test_extract_failure_is_all_unknown(monkeypatch):
    async def _boom(*a, **k):
        raise RuntimeError("vision down")

    monkeypatch.setattr(gemini, "generate_json", _boom)
    out = asyncio.run(photo_attrs.extract_attributes(b"X", "image/jpeg"))
    assert set(out.values()) == {"unknown"}
