"""Unit tests for cleanup_stored_face_embeddings.py."""

from scripts.cleanup_stored_face_embeddings import cleanup_embeddings


class _FakeDocRef:
    def __init__(self, doc_id, data, parent_store):
        self.id = doc_id
        self._data = data
        self._store = parent_store
        self.updates = []

    def to_dict(self):
        return dict(self._data)

    @property
    def reference(self):
        return self

    def update(self, fields):
        self.updates.append(fields)
        for k in fields:
            if "." in k:
                top, sub = k.split(".", 1)
                if top in self._data and isinstance(self._data[top], dict):
                    self._data[top].pop(sub, None)
            else:
                self._data.pop(k, None)

    def collection(self, name):
        class _SubColl:
            def __init__(sub_self):
                sub_self.name = name

            def stream(sub_self):
                sub_docs = self._store.get((self.id, name), [])
                return sub_docs
        return _SubColl()


class _FakeDb:
    def __init__(self, users_dict, subcoll_dict):
        self._users = users_dict
        self._sub = subcoll_dict

    def collection(self, name):
        class _Coll:
            def stream(coll_self):
                if name == "users":
                    return [
                        _FakeDocRef(uid, data, self._sub)
                        for uid, data in self._users.items()
                    ]
                return []
        return _Coll()


def test_cleanup_embeddings_dry_run_and_apply():
    users = {
        "u1": {
            "face_verification": {"embedding": [0.1, 0.2], "storage_path": "s.jpg"},
        },
        "u2": {
            "face_verification": {"storage_path": "s2.jpg"},
        },
    }
    m1 = _FakeDocRef("m1", {"storage_path": "p1.jpg", "embedding": [0.1], "dim": 1}, {})
    n1 = _FakeDocRef("n1", {"url": "u1", "embedding": [0.2], "is_user": "yes"}, {})
    subcoll = {
        ("u1", "user_media"): [m1],
        ("u1", "photo_notes"): [n1],
        ("u2", "user_media"): [],
        ("u2", "photo_notes"): [],
    }

    db = _FakeDb(users, subcoll)

    # 1. Dry run
    report_dry = cleanup_embeddings(db, dry_run=True)
    assert report_dry["users_scanned"] == 2
    assert report_dry["face_verification_embeddings_deleted"] == 1
    assert report_dry["user_media_embeddings_deleted"] == 1
    assert report_dry["photo_notes_embeddings_deleted"] == 1
    assert report_dry["dry_run"] == 1
    # Verify not actually deleted yet
    assert "embedding" in users["u1"]["face_verification"]

    # 2. Apply run
    report_apply = cleanup_embeddings(db, dry_run=False)
    assert report_apply["users_scanned"] == 2
    assert report_apply["face_verification_embeddings_deleted"] == 1
    assert report_apply["user_media_embeddings_deleted"] == 1
    assert report_apply["photo_notes_embeddings_deleted"] == 1
    assert report_apply["dry_run"] == 0
    # Verified deleted
    assert "embedding" not in users["u1"]["face_verification"]
    assert len(m1.updates) == 1
    assert len(n1.updates) == 1
