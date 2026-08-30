import photo_ops
import pytest


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


def _db_with_media(*media_ids, photos=None):
    seed = {}
    for m in media_ids:
        seed[("users", "u1", "user_media", m)] = {"storage_path": f"uploads/u1/{m}"}
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
    with pytest.raises(ValueError):
        photo_ops.add_photo(_db_with_media(), "u1", "ghost")


def test_remove_photo_is_soft_and_renumbers():
    db = _db_with_media(
        "m1", "m2", "m3",
        photos=[
            {"media_id": "m1", "order": 0},
            {"media_id": "m2", "order": 1},
            {"media_id": "m3", "order": 2},
        ],
    )
    photo_ops.remove_photo(db, "u1", "m2")
    assert _grid(db) == [
        {"media_id": "m1", "order": 0},
        {"media_id": "m3", "order": 1},
    ]
    # user_media docs are untouched
    assert db.store[("users", "u1", "user_media", "m2")] == {
        "storage_path": "uploads/u1/m2"
    }


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
