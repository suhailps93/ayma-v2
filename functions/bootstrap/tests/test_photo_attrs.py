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
    async def _fake(contents, system_prompt, response_schema=None, image=None, **_kw):
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


def test_upper_body_counts_as_usable_even_if_model_said_no(monkeypatch):
    # § founder report: a sitting, clothed, body-visible photo and a cropped
    # mirror selfie were both excluded because the old prompt required
    # "full-length / standing". usable_for_body is now derived from
    # shot_type, not the model's own (possibly stale-prompt) judgment — an
    # upper_body shot counts regardless of what the model itself returned
    # for the boolean.
    async def _fake(contents, system_prompt, response_schema=None, image=None, **_kw):
        return {
            "shot_type": "upper_body",
            "usable_for_body": False,  # model's own stale judgment — ignored
        }

    monkeypatch.setattr(gemini, "generate_json", _fake)
    out = asyncio.run(photo_attrs.extract_attributes(b"IMG", "image/png"))
    assert out["shot_type"] == "upper_body"
    assert out["usable_for_body"] is True


def test_face_and_group_never_count_as_usable_for_body(monkeypatch):
    for shot_type in ("face", "group"):
        async def _fake(contents, system_prompt, response_schema=None,
                         image=None, _st=shot_type):
            return {"shot_type": _st, "usable_for_body": True}

        monkeypatch.setattr(gemini, "generate_json", _fake)
        out = asyncio.run(photo_attrs.extract_attributes(b"IMG", "image/png"))
        assert out["usable_for_body"] is False, shot_type


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
    assert cov == {
        "has_face_photo": True,
        "has_body_photo": True,
        "has_fitted_body_photo": True,
    }


def test_coverage_is_false_when_untagged():
    docs = {
        ("users", "u1", "profile", "main"): {
            "photos": [{"media_id": "m1", "order": 0}]
        },
        ("users", "u1", "user_media", "m1"): {"attributes": {}},
    }
    cov = photo_attrs.coverage(_Db(docs), "u1")
    assert cov == {
        "has_face_photo": False,
        "has_body_photo": False,
        "has_fitted_body_photo": False,
    }


def test_coverage_flags_loose_clothing_as_not_fitted():
    docs = {
        ("users", "u1", "profile", "main"): {
            "photos": [{"media_id": "m1", "order": 0}]
        },
        ("users", "u1", "user_media", "m1"): {
            "attributes": {
                "shot_type": "full_body",
                "usable_for_body": True,
                "loose_clothing": True,
            }
        },
    }
    cov = photo_attrs.coverage(_Db(docs), "u1")
    assert cov["has_body_photo"] is True
    assert cov["has_fitted_body_photo"] is False


# --- eligibility (pre-run face/body grouping) -------------------------------


def test_eligibility_groups_grid_photos_by_axis(monkeypatch):
    # m1 = face only, m2 = body only, m3 = both (a full body with a clear face).
    monkeypatch.setattr(
        photo_attrs, "_grid_media_ids", lambda prof: ["m1", "m2", "m3"]
    )
    import public_profile

    monkeypatch.setattr(public_profile, "_photo_url", lambda sp: f"https://cdn/{sp}")
    docs = {
        ("users", "u1", "profile", "main"): {"photos": [{"media_id": "m1"}]},
        ("users", "u1", "user_media", "m1"): {
            "storage_path": "p1.jpg",
            "attributes": {"usable_for_face": True, "usable_for_body": False},
        },
        ("users", "u1", "user_media", "m2"): {
            "storage_path": "p2.jpg",
            "attributes": {"usable_for_face": False, "usable_for_body": True},
        },
        ("users", "u1", "user_media", "m3"): {
            "storage_path": "p3.jpg",
            "attributes": {"usable_for_face": True, "usable_for_body": True},
        },
    }
    out = photo_attrs.eligibility(_Db(docs), "u1")
    assert [e["media_id"] for e in out["face"]] == ["m1", "m3"]
    assert [e["media_id"] for e in out["body"]] == ["m2", "m3"]
    assert out["face"][0]["url"] == "https://cdn/p1.jpg"
    assert out["has_face_photo"] is True and out["has_body_photo"] is True


def test_eligibility_empty_body_group_when_only_a_face_photo(monkeypatch):
    monkeypatch.setattr(photo_attrs, "_grid_media_ids", lambda prof: ["m1"])
    import public_profile

    monkeypatch.setattr(public_profile, "_photo_url", lambda sp: "https://cdn/x")
    docs = {
        ("users", "u1", "profile", "main"): {"photos": [{"media_id": "m1"}]},
        ("users", "u1", "user_media", "m1"): {
            "storage_path": "p1.jpg",
            "attributes": {"usable_for_face": True, "usable_for_body": False},
        },
    }
    out = photo_attrs.eligibility(_Db(docs), "u1")
    assert out["face"] and out["body"] == []
    assert out["has_body_photo"] is False


def test_eligibility_surfaces_untagged_photos_in_both_buckets(monkeypatch):
    # § founder 2026-10-28: an untagged / ambiguous photo must not be hidden.
    # It is surfaced in BOTH buckets so the user can pick, while has_* stay the
    # honest coverage signal (no usable-for-axis photo really exists yet).
    monkeypatch.setattr(photo_attrs, "_grid_media_ids", lambda prof: ["m1", "m2"])
    import public_profile

    monkeypatch.setattr(public_profile, "_photo_url", lambda sp: f"https://cdn/{sp}")
    docs = {
        ("users", "u1", "profile", "main"): {"photos": [{"media_id": "m1"}]},
        # m1 untagged (no attributes yet), m2 a clear face-only shot.
        ("users", "u1", "user_media", "m1"): {"storage_path": "p1.jpg"},
        ("users", "u1", "user_media", "m2"): {
            "storage_path": "p2.jpg",
            "attributes": {"usable_for_face": True, "usable_for_body": False},
        },
    }
    out = photo_attrs.eligibility(_Db(docs), "u1")
    assert [e["media_id"] for e in out["face"]] == ["m1", "m2"]
    # the untagged m1 shows for body too; the face-only m2 never does.
    assert [e["media_id"] for e in out["body"]] == ["m1"]
    assert out["has_face_photo"] is True  # m2 is a real usable face photo
    assert out["has_body_photo"] is False  # no real usable body photo exists


def _elig_by_id(out, axis):
    return {e["media_id"]: e for e in out[axis]}


def test_eligibility_auto_select_rules_by_shot_type(monkeypatch):
    # § founder 2026-10-28 screenshot bug. Photos:
    #   solo_face      -> single clear face, no body  (shot_type face)
    #   solo_body      -> one body visible, no clear face (shot_type full_body)
    #   solo_full      -> one person, face + body (shot_type full_body, uf+ub)
    #   couple_face    -> two people, a face/couple close-up (shot_type group)
    #   untagged       -> no attributes yet
    monkeypatch.setattr(
        photo_attrs,
        "_grid_media_ids",
        lambda prof: ["solo_face", "solo_body", "solo_full", "couple_face", "untagged"],
    )
    import public_profile

    monkeypatch.setattr(public_profile, "_photo_url", lambda sp: f"https://cdn/{sp}")
    docs = {
        ("users", "u1", "profile", "main"): {"photos": [{"media_id": "solo_face"}]},
        ("users", "u1", "user_media", "solo_face"): {
            "storage_path": "p1.jpg",
            "attributes": {
                "shot_type": "face",
                "usable_for_face": True,
                "usable_for_body": False,
            },
        },
        ("users", "u1", "user_media", "solo_body"): {
            "storage_path": "p2.jpg",
            "attributes": {
                "shot_type": "full_body",
                "usable_for_face": False,
                "usable_for_body": True,
            },
        },
        ("users", "u1", "user_media", "solo_full"): {
            "storage_path": "p3.jpg",
            "attributes": {
                "shot_type": "full_body",
                "usable_for_face": True,
                "usable_for_body": True,
            },
        },
        ("users", "u1", "user_media", "couple_face"): {
            "storage_path": "p4.jpg",
            "attributes": {
                "shot_type": "group",
                "usable_for_face": False,
                "usable_for_body": False,
            },
        },
        ("users", "u1", "user_media", "untagged"): {"storage_path": "p5.jpg"},
    }
    out = photo_attrs.eligibility(_Db(docs), "u1")
    face = _elig_by_id(out, "face")
    body = _elig_by_id(out, "body")

    # Bug 1: a multi-person photo is NEVER auto-selected, in either axis — even
    # though it is still surfaced in both buckets so the user could pick it.
    assert "couple_face" in face and "couple_face" in body
    assert face["couple_face"]["multi_person"] is True
    assert face["couple_face"]["person_count"] == 2
    assert face["couple_face"]["auto_select"] is False
    assert body["couple_face"]["auto_select"] is False

    # Bug 2: a face-only / no-body photo is not even surfaced for body, and a
    # body-only / no-face photo is not surfaced for face.
    assert "solo_face" not in body
    assert "solo_body" not in face

    # Solo body -> auto-selected into Body; solo face -> auto-selected into Face.
    assert body["solo_body"]["auto_select"] is True
    assert body["solo_body"]["person_count"] == 1
    assert face["solo_face"]["auto_select"] is True
    assert face["solo_face"]["person_count"] == 1

    # A solo full shot (face + body) is auto-selected for both axes.
    assert face["solo_full"]["auto_select"] is True
    assert body["solo_full"]["auto_select"] is True

    # Defensive: an untagged photo is surfaced (both buckets) but never
    # pre-checked, since we can't verify it is solo + the right type.
    assert "untagged" in face and "untagged" in body
    assert face["untagged"]["auto_select"] is False
    assert body["untagged"]["auto_select"] is False
    assert face["untagged"]["person_count"] == 0


# --- resync_usable_for_body -------------------------------------------------


class _StreamSnap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    def to_dict(self):
        return dict(self._data)


class _StreamDoc:
    def __init__(self, store, key):
        self._store, self._key = store, key

    def collection(self, name):
        return _StreamColl(self._store, self._key + (name,))

    def set(self, data, merge=False):
        cur = self._store.get(self._key, {})
        if merge and isinstance(cur, dict):
            self._store[self._key] = {**cur, **data}
        else:
            self._store[self._key] = dict(data)


class _StreamColl:
    def __init__(self, store, key):
        self._store, self._key = store, key

    def document(self, doc_id):
        return _StreamDoc(self._store, self._key + (doc_id,))

    def stream(self):
        depth = len(self._key)
        seen = set()
        for k in list(self._store.keys()):
            if len(k) > depth and k[:depth] == self._key and k[depth] not in seen:
                seen.add(k[depth])
                child_key = self._key + (k[depth],)
                yield _StreamSnap(k[depth], self._store.get(child_key, {}))


class _StreamDb:
    def __init__(self, docs):
        self._store = dict(docs)

    def collection(self, name):
        return _StreamColl(self._store, (name,))


def test_resync_fixes_a_stale_usable_for_body_from_stored_shot_type():
    # § founder report exact scenario: an already-tagged sitting/clothed
    # body photo (upper_body) was marked unusable by the old rule.
    docs = {
        ("users", "u1"): {},
        ("users", "u1", "user_media", "sitting"): {
            "attributes": {
                "shot_type": "upper_body",
                "usable_for_body": False,
                "usable_for_face": False,
            }
        },
        ("users", "u1", "user_media", "face"): {
            "attributes": {
                "shot_type": "face",
                "usable_for_body": False,
                "usable_for_face": True,
            }
        },
        ("users", "u1", "user_media", "already_right"): {
            "attributes": {"shot_type": "full_body", "usable_for_body": True},
        },
    }
    db = _StreamDb(docs)

    out = asyncio.run(photo_attrs.resync_usable_for_body(db))

    assert out == {"users": 1, "photos_fixed": 1}
    fixed = db._store[("users", "u1", "user_media", "sitting")]["attributes"]
    assert fixed["usable_for_body"] is True
    assert fixed["usable_for_face"] is False  # untouched
    # face photo stays excluded; already-correct photo untouched (not
    # counted in photos_fixed since nothing changed).
    assert db._store[("users", "u1", "user_media", "face")]["attributes"][
        "usable_for_body"
    ] is False


def test_resync_skips_photos_with_no_attributes():
    docs = {
        ("users", "u1"): {},
        ("users", "u1", "user_media", "m1"): {},
    }
    out = asyncio.run(photo_attrs.resync_usable_for_body(_StreamDb(docs)))
    assert out == {"users": 1, "photos_fixed": 0}
