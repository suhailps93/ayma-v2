import asyncio

import gemini
import photo_attrs


def test_schema_and_fields():
    fields = photo_attrs.attribute_fields()
    assert "hair_color" in fields and "glasses" in fields
    # Shot-type tags ride on the same per-photo record.
    assert "shot_type" in fields
    assert "usable_for_face" in fields and "usable_for_body" in fields
    schema = photo_attrs._response_schema()
    assert schema["properties"]["glasses"]["enum"] == ["yes", "no", "unknown"]
    assert schema["properties"]["shot_type"]["enum"] == list(photo_attrs.SHOT_TYPES)
    assert schema["properties"]["usable_for_face"]["type"] == "boolean"


def test_extract_returns_all_fields(monkeypatch):
    async def _fake(contents, system_prompt, response_schema=None, image=None):
        assert image == (b"IMG", "image/png")
        return {
            "hair_color": "brown",
            "glasses": "yes",
            "shot_type": "full_body",
            "usable_for_face": True,
            "usable_for_body": True,
        }

    monkeypatch.setattr(gemini, "generate_json", _fake)
    out = asyncio.run(photo_attrs.extract_attributes(b"IMG", "image/png"))
    assert set(out) == set(photo_attrs.attribute_fields())
    assert out["hair_color"] == "brown"
    assert out["eye_color"] == "unknown"  # absent -> unknown
    assert out["shot_type"] == "full_body"
    assert out["usable_for_face"] is True
    assert out["usable_for_body"] is True


def test_extract_coerces_a_bad_shot_type_and_missing_flags(monkeypatch):
    async def _fake(*a, **k):
        return {"hair_color": "brown", "shot_type": "selfie"}

    monkeypatch.setattr(gemini, "generate_json", _fake)
    out = asyncio.run(photo_attrs.extract_attributes(b"IMG", "image/png"))
    assert out["shot_type"] == "other"  # unknown value -> other
    assert out["usable_for_face"] is False
    assert out["usable_for_body"] is False


def test_extract_failure_is_a_blank_record(monkeypatch):
    async def _boom(*a, **k):
        raise RuntimeError("vision down")

    monkeypatch.setattr(gemini, "generate_json", _boom)
    out = asyncio.run(photo_attrs.extract_attributes(b"X", "image/jpeg"))
    assert set(out) == set(photo_attrs.attribute_fields())
    assert out["hair_color"] == "unknown" and out["glasses"] == "unknown"
    assert out["shot_type"] == "other"
    assert out["usable_for_face"] is False and out["usable_for_body"] is False


# --- coverage --------------------------------------------------------------


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _Doc:
    def __init__(self, store, key):
        self._store, self._key = store, key

    def get(self):
        return _Snap(self._store.get(self._key))

    def collection(self, name):
        return _Coll(self._store, self._key + (name,))


class _Coll:
    def __init__(self, store, key):
        self._store, self._key = store, key

    def document(self, name):
        return _Doc(self._store, self._key + (name,))


class _Db:
    def __init__(self, docs):
        self._docs = docs

    def get(self, key):
        return self._docs.get(key)

    def collection(self, name):
        return _Coll(self, (name,))


def test_coverage_reads_shot_tags_off_the_grid():
    docs = {
        ("users", "u1", "profile", "main"): {
            "photos": [
                {"media_id": "m1", "order": 0},
                {"media_id": "m2", "order": 1},
            ]
        },
        ("users", "u1", "user_media", "m1"): {
            "attributes": {"shot_type": "face", "usable_for_face": True,
                           "usable_for_body": False}
        },
        ("users", "u1", "user_media", "m2"): {
            "attributes": {"shot_type": "full_body", "usable_for_face": False,
                           "usable_for_body": True}
        },
    }
    cov = photo_attrs.coverage(_Db(docs), "u1")
    assert cov == {"has_face_photo": True, "has_body_photo": True}


def test_coverage_is_false_when_untagged():
    docs = {
        ("users", "u1", "profile", "main"): {
            "photos": [{"media_id": "m1", "order": 0}]
        },
        ("users", "u1", "user_media", "m1"): {"attributes": {}},
    }
    cov = photo_attrs.coverage(_Db(docs), "u1")
    assert cov == {"has_face_photo": False, "has_body_photo": False}
