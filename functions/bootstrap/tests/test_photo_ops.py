import photo_ops
import pytest
import schema


class _Doc:
    def __init__(self, store, key):
        self._s, self._k = store, key

    def get(self):
        data = self._s.get(self._k)
        outer = self

        class _S:
            exists = data is not None

            def to_dict(self_):
                return dict(data) if data else {}

        return _S()

    def set(self, payload, merge=False):
        cur = dict(self._s.get(self._k) or {}) if merge else {}
        cur.update(payload)
        self._s[self._k] = cur

    def delete(self):
        self._s.pop(self._k, None)

    def collection(self, name):
        return _Col(self._s, self._k + (name,))


class _Col:
    def __init__(self, store, key):
        self._s, self._k = store, key

    def document(self, doc_id):
        return _Doc(self._s, self._k + (doc_id,))


class _Db:
    def __init__(self, seed=None):
        self.store = dict(seed or {})

    def collection(self, name):
        return _Col(self.store, (name,))


def _db_with_media(*media_ids, photos=None, status="approved", extra=None):
    """Seed ``user_media`` docs. ``media_ids`` all get ``moderation_status``
    ``status`` (default the approved value that clears the grid); ``extra`` is a
    ``{media_id: moderation_status}`` map for docs with a different status
    (pass ``None`` to seed a doc with no status field at all)."""
    seed = {}
    for m in media_ids:
        seed[("users", "u1", "user_media", m)] = {
            "storage_path": f"uploads/u1/{m}",
            "moderation_status": status,
        }
    for m, st in (extra or {}).items():
        doc = {"storage_path": f"uploads/u1/{m}"}
        if st is not None:
            doc["moderation_status"] = st
        seed[("users", "u1", "user_media", m)] = doc
    if photos is not None:
        seed[("users", "u1", "profile", "main")] = {"photos": photos}
    return _Db(seed)


def _grid(db):
    return db.store.get(("users", "u1", "profile", "main"), {}).get("photos")


def test_add_photo_appends_with_order_and_dedupes():
    db = _db_with_media("m1", "m2")
    photo_ops.add_photo(db, "u1", "m1")
    photo_ops.add_photo(db, "u1", "m2")
    photo_ops.add_photo(db, "u1", "m1")  # dupe
    assert _grid(db) == [
        {"media_id": "m1", "order": 0},
        {"media_id": "m2", "order": 1},
    ]


def test_add_photo_rejects_unknown_media():
    db = _db_with_media()
    with pytest.raises(ValueError):
        photo_ops.add_photo(db, "u1", "ghost")
    assert _grid(db) is None


@pytest.mark.parametrize(
    "bad_status",
    ["flagged", "pending", "moderation_error", "", None],
    ids=["flagged", "pending", "error", "empty", "missing"],
)
def test_add_photo_rejects_media_without_affirmative_approval(bad_status):
    """The pipeline keeps a ``user_media`` doc for rejected/held photos. Adding
    one of those ids must fail closed and never touch the grid (R2a / §8.4)."""
    db = _db_with_media("ok", extra={"bad": bad_status})
    with pytest.raises(ValueError):
        photo_ops.add_photo(db, "u1", "bad")
    assert _grid(db) is None

    # A genuinely approved id in the same store still works — the gate is on
    # status, not a blanket block.
    photo_ops.add_photo(db, "u1", "ok")
    assert _grid(db) == [{"media_id": "ok", "order": 0}]


def test_add_photo_rejection_leaves_an_existing_grid_untouched():
    db = _db_with_media(
        "keep",
        photos=[{"media_id": "keep", "order": 0}],
        extra={"flagged": "flagged"},
    )
    with pytest.raises(ValueError):
        photo_ops.add_photo(db, "u1", "flagged")
    assert _grid(db) == [{"media_id": "keep", "order": 0}]


def test_add_photos_batches_several_in_one_call():
    db = _db_with_media("m1", "m2", "m3")
    result = photo_ops.add_photos(db, "u1", ["m1", "m2", "m3"])
    assert result["added"] == ["m1", "m2", "m3"]
    assert result["failed"] == []
    assert result["photos"] == [
        {"media_id": "m1", "order": 0},
        {"media_id": "m2", "order": 1},
        {"media_id": "m3", "order": 2},
    ]
    assert _grid(db) == result["photos"]


def test_add_photos_one_bad_id_does_not_block_the_rest():
    db = _db_with_media("ok1", "ok2", extra={"bad": "flagged"})
    result = photo_ops.add_photos(db, "u1", ["ok1", "bad", "ok2"])
    assert result["added"] == ["ok1", "ok2"]
    assert len(result["failed"]) == 1
    assert result["failed"][0]["media_id"] == "bad"
    assert result["failed"][0]["error"]
    assert _grid(db) == [
        {"media_id": "ok1", "order": 0},
        {"media_id": "ok2", "order": 1},
    ]


def test_add_photos_all_failing_still_returns_the_untouched_grid():
    db = _db_with_media(
        "keep", photos=[{"media_id": "keep", "order": 0}],
        extra={"bad": "flagged"},
    )
    result = photo_ops.add_photos(db, "u1", ["bad"])
    assert result["added"] == []
    assert len(result["failed"]) == 1
    assert result["photos"] == [{"media_id": "keep", "order": 0}]


def _hidden(db):
    return db.store.get(("users", "u1", "profile", "main"), {}).get(
        "hidden_photos"
    )


def test_remove_photo_hides_from_public_but_keeps_for_analysis():
    db = _db_with_media(
        "m1", "m2", "m3",
        photos=[
            {"media_id": "m1", "order": 0},
            {"media_id": "m2", "order": 1},
            {"media_id": "m3", "order": 2},
        ],
    )
    photo_ops.remove_photo(db, "u1", "m2")
    # Gone from the public grid, renumbered…
    assert _grid(db) == [
        {"media_id": "m1", "order": 0},
        {"media_id": "m3", "order": 1},
    ]
    # …but kept in the hidden list for analysis…
    assert _hidden(db) == [{"media_id": "m2", "order": 0}]
    # …and the analysis pool still includes it (public first, hidden after).
    prof = db.store[("users", "u1", "profile", "main")]
    assert [p["media_id"] for p in schema.analysis_photo_entries(prof)] == [
        "m1", "m3", "m2",
    ]
    # user_media docs are untouched (remove is soft — the media record stays,
    # moderation status and all)
    assert db.store[("users", "u1", "user_media", "m2")] == {
        "storage_path": "uploads/u1/m2",
        "moderation_status": "approved",
    }


def test_remove_then_readd_restores_from_hidden_without_duplicating():
    db = _db_with_media(
        "m1", "m2",
        photos=[
            {"media_id": "m1", "order": 0},
            {"media_id": "m2", "order": 1},
        ],
    )
    photo_ops.remove_photo(db, "u1", "m2")
    assert _hidden(db) == [{"media_id": "m2", "order": 0}]
    photo_ops.add_photo(db, "u1", "m2")  # re-add (undo a committed removal)
    assert _grid(db) == [
        {"media_id": "m1", "order": 0},
        {"media_id": "m2", "order": 1},
    ]
    assert _hidden(db) == []  # not left behind in the hidden list


def test_set_primary_moves_a_photo_to_the_front():
    db = _db_with_media(
        "a", "b", "c",
        photos=[
            {"media_id": "a", "order": 0},
            {"media_id": "b", "order": 1},
            {"media_id": "c", "order": 2},
        ],
    )
    photo_ops.set_primary(db, "u1", "c")
    assert _grid(db) == [
        {"media_id": "c", "order": 0},
        {"media_id": "a", "order": 1},
        {"media_id": "b", "order": 2},
    ]


def test_set_primary_is_a_noop_for_a_non_public_photo():
    db = _db_with_media(
        "a", "b",
        photos=[{"media_id": "a", "order": 0}, {"media_id": "b", "order": 1}],
    )
    photo_ops.remove_photo(db, "u1", "b")  # b is now hidden
    photo_ops.set_primary(db, "u1", "b")  # can't promote a hidden photo
    assert _grid(db) == [{"media_id": "a", "order": 0}]


class _DelBucket:
    def __init__(self):
        self.deleted = []

    def blob(self, path):
        bucket = self

        class _Blob:
            def delete(self_):
                bucket.deleted.append(path)

        return _Blob()


def test_delete_permanent_erases_the_media_everywhere():
    db = _db_with_media(
        "m1", "m2",
        photos=[{"media_id": "m1", "order": 0}, {"media_id": "m2", "order": 1}],
    )
    photo_ops.remove_photo(db, "u1", "m2")  # m2 hidden
    bucket = _DelBucket()
    photo_ops.delete_photo_permanent(db, "u1", "m2", bucket)
    assert _grid(db) == [{"media_id": "m1", "order": 0}]
    assert _hidden(db) == []  # dropped from the hidden list too
    # The media doc and its Storage blob are gone (analysis erased).
    assert ("users", "u1", "user_media", "m2") not in db.store
    assert bucket.deleted == ["uploads/u1/m2"]


def test_reorder_photos_sets_primary_and_keeps_unlisted_at_end():
    db = _db_with_media(
        "a", "b", "c",
        photos=[
            {"media_id": "a", "order": 0},
            {"media_id": "b", "order": 1},
            {"media_id": "c", "order": 2},
        ],
    )
    photo_ops.reorder_photos(db, "u1", ["c", "a"])
    assert _grid(db) == [
        {"media_id": "c", "order": 0},
        {"media_id": "a", "order": 1},
        {"media_id": "b", "order": 2},
    ]
