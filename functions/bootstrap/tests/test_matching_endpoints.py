import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def test_run_matching_requires_a_token():
    assert client.post("/run-matching").status_code in (401, 403)


def test_run_matching_invokes_pass1(monkeypatch):
    # Heuristic-only pass — no Gemini, so no credit gate here.
    monkeypatch.setattr(
        main.matching, "source_and_score",
        lambda db, uid, limit: [{"candidate_uid": "x"}, {"candidate_uid": "y"}],
    )
    resp = client.post("/run-matching", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json() == {"ok": True, "candidates": 2}


def test_check_compatibility_rejects_self(monkeypatch):
    resp = client.post(
        "/check-compatibility",
        headers=_auth(monkeypatch, uid="me"),
        json={"other_uid": "me"},
    )
    assert resp.status_code == 400


def test_check_compatibility_reports_usage_capped_when_out_of_budget(
    monkeypatch,
):
    def _capped(uid):
        raise main.token_ledger.TokenCapExceeded("no budget")

    monkeypatch.setattr(main.token_ledger, "check", _capped)
    resp = client.post(
        "/check-compatibility",
        headers=_auth(monkeypatch, uid="me"),
        json={"other_uid": "them"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": False, "usage_capped": True}


def test_check_compatibility_queues_and_the_job_writes_the_match_doc(monkeypatch):
    async def _fake_score(db, a, b):
        return {
            "score": 0.62,
            "raw_score": 0.62,
            "structured_score": 64.0,
            "dimensions": [
                {"key": "values", "label": "Values & worldview",
                 "weight": 0.22, "score": 70.0, "rationale": "r",
                 "evidence": ["Kids & timeline: ..."], "confidence": "high",
                 "source": "structured", "covered_nodes": ["procreation_intent"]},
            ],
            "user_explanation": {a: "for you", b: "for them"},
            "ai_explanation": "private",
            "shared": ["both love hiking"],
            "tensions": ["different cities"],
            "missing": ["kids & timeline for both"],
            "gate_failures": [
                {"node_id": "relationship_intent",
                 "label": "Relationship intent",
                 "reason": "One is here for something casual."},
            ],
            "score_confidence": 0.71,
            "confidence_note": "High confidence — both profiles are detailed.",
            "method": "structured + llm",
            "trust_flags": {a: [], b: []},
        }

    async def _no_notify(*a, **k):
        return None

    monkeypatch.setattr(main.matching_skill, "score_pair", _fake_score)
    monkeypatch.setattr(main.token_ledger, "check", lambda uid: None)
    monkeypatch.setattr(main, "_profile_full_name", lambda _u: "Their Name")
    monkeypatch.setattr(
        main.notifications_triggers, "notify_skill_done", _no_notify
    )

    writes = {}

    class _Ref:
        def get(self):
            class _S:
                exists = False

            return _S()

        def set(self, payload, merge=False):
            writes.update(payload)

    class _Db:
        def collection(self, name):  # matches only reaches here
            return self

        def document(self, mid):
            writes["_id"] = mid
            return _Ref()

    monkeypatch.setattr(main, "get_db", lambda: _Db())
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")

    # TestClient runs the background task synchronously after the response.
    resp = client.post(
        "/check-compatibility",
        headers=_auth(monkeypatch, uid="bbb"),
        json={"other_uid": "aaa"},
    )
    assert resp.status_code == 200
    assert resp.json() == {
        "ok": True, "queued": True, "match_id": "aaa__bbb"
    }
    assert writes["uids"] == ["aaa", "bbb"]
    assert writes["status"] == "scored"
    assert writes["shared"] == ["both love hiking"]
    assert writes["missing"] == ["kids & timeline for both"]
    assert writes["dimensions"][0]["key"] == "values"
    assert writes["dimensions"][0]["source"] == "structured"
    assert writes["user_explanation"] == {"bbb": "for you", "aaa": "for them"}
    assert writes["score_confidence"] == 0.71
    assert writes["confidence_note"].startswith("High confidence")
    assert writes["gate_failures"][0]["node_id"] == "relationship_intent"
    assert writes["structured_score"] == 64.0


def test_match_report_returns_stored_breakdown_and_photos(monkeypatch):
    monkeypatch.setattr(main.token_ledger, "check", lambda uid: None)

    doc = {
        "score": 0.52,
        "structured_score": 55.0,
        "shared": ["both want kids soon"],
        "tensions": ["she wants city, he wants small town"],
        "missing": ["how conflict gets handled after a fight"],
        "gate_failures": [
            {"node_id": "procreation_intent", "label": "Kids & timeline",
             "reason": "One is firmly childfree; the other wants children."},
        ],
        "score_confidence": 0.44,
        "confidence_note": "Medium confidence — some gaps remain.",
        "method": "structured + llm",
        "user_explanation": {"me": "you two line up on family", "them": "x"},
        "updated_at": "TS",
    }

    class _Ref:
        def get(self):
            class _S:
                exists = True

                def to_dict(_s):
                    return dict(doc)

            return _S()

    class _Db:
        def collection(self, name):
            assert name == "matches"
            return self

        def document(self, _mid):
            return _Ref()

    monkeypatch.setattr(main, "get_db", lambda: _Db())
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda u: f"p/{u}")
    monkeypatch.setattr(
        main.story, "_photo_url_safe", lambda sp: f"https://cdn/{sp}"
    )
    monkeypatch.setattr(main, "_profile_full_name", lambda u: "Their Name")

    resp = client.get("/match/me__them", headers=_auth(monkeypatch, uid="me"))
    assert resp.status_code == 200
    body = resp.json()
    assert body["score"] == 0.52
    assert body["structured_score"] == 55.0
    assert body["shared"] == ["both want kids soon"]
    assert body["missing"] == ["how conflict gets handled after a fight"]
    assert body["score_confidence"] == 0.44
    assert body["confidence_note"] == "Medium confidence — some gaps remain."
    assert body["gate_failures"][0]["node_id"] == "procreation_intent"
    assert body["method"] == "structured + llm"
    assert body["explanation"] == "you two line up on family"
    assert body["other"] == {
        "uid": "them", "name": "Their Name", "photo": "https://cdn/p/them"
    }
    assert body["me"]["photo"] == "https://cdn/p/me"


def test_match_report_404_when_never_scored(monkeypatch):
    class _Ref:
        def get(self):
            class _S:
                exists = False

            return _S()

    class _Db:
        def collection(self, _n):
            return self

        def document(self, _m):
            return _Ref()

    monkeypatch.setattr(main, "get_db", lambda: _Db())
    resp = client.get("/match/me__them", headers=_auth(monkeypatch, uid="me"))
    assert resp.status_code == 404


def test_match_report_rejects_a_non_participant(monkeypatch):
    resp = client.get(
        "/match/aaa__bbb", headers=_auth(monkeypatch, uid="stranger")
    )
    assert resp.status_code == 403


class _FakeBlockDb:
    """Handles both the ``blocks`` write and the ``dm_threads`` hide step."""

    def __init__(self, thread_exists):
        self.thread_exists = thread_exists
        self.block_writes = {}
        self.thread_writes = {}
        self._col = None

    def collection(self, name):
        self._col = name
        return self

    def document(self, doc_id):
        col = self._col
        parent = self

        class _Ref:
            def set(self, payload, merge=False):
                if col == "blocks":
                    parent.block_writes.update(payload)
                    parent.block_writes["_id"] = doc_id
                else:
                    parent.thread_writes.update(payload)
                    parent.thread_writes["_id"] = doc_id

            def get(self):
                class _S:
                    exists = parent.thread_exists

                return _S()

        return _Ref()


def test_block_writes_a_block_doc(monkeypatch):
    db = _FakeBlockDb(thread_exists=False)
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")
    resp = client.post(
        "/block", headers=_auth(monkeypatch, uid="me"),
        json={"blocked_uid": "them"},
    )
    assert resp.status_code == 200
    assert db.block_writes["_id"] == "me_them"
    assert db.block_writes["blocker"] == "me"
    assert db.block_writes["blocked"] == "them"
    assert db.thread_writes == {}  # no thread to hide


def test_block_hides_existing_dm_thread(monkeypatch):
    db = _FakeBlockDb(thread_exists=True)
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")
    resp = client.post(
        "/block", headers=_auth(monkeypatch, uid="me"),
        json={"blocked_uid": "them"},
    )
    assert resp.status_code == 200
    assert db.thread_writes["_id"] == "me__them"
    assert "me" in db.thread_writes["hidden_for"].values


def test_block_rejects_self(monkeypatch):
    resp = client.post(
        "/block", headers=_auth(monkeypatch, uid="me"),
        json={"blocked_uid": "me"},
    )
    assert resp.status_code == 400


def _match_db(monkeypatch, data):
    store = {"data": data}

    class _Ref:
        def get(self):
            class _S:
                exists = data is not None

                def to_dict(self_):
                    return dict(store["data"]) if store["data"] else None

            return _S()

        def set(self, payload, merge=False):
            store["data"] = {**(store["data"] or {}), **payload}

    class _Db:
        def collection(self, _):
            return self

        def document(self, _):
            return _Ref()

    monkeypatch.setattr(main, "get_db", lambda: _Db())
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")
    return store


def test_match_reject_unmatches(monkeypatch):
    store = _match_db(monkeypatch, {"uids": ["a", "me"], "status": "scored"})
    resp = client.post(
        "/match/a__me/respond",
        headers=_auth(monkeypatch, uid="me"),
        json={"response": "reject"},
    )
    assert resp.json() == {"ok": True, "status": "unmatched"}
    assert store["data"]["status"] == "unmatched"


def test_match_accept_flips_to_mutual_when_both_accept(monkeypatch):
    store = _match_db(
        monkeypatch,
        {"uids": ["a", "me"], "status": "scored", "accepted_by": ["a"]},
    )
    resp = client.post(
        "/match/a__me/respond",
        headers=_auth(monkeypatch, uid="me"),
        json={"response": "accept"},
    )
    assert resp.json()["status"] == "mutual_interest"
    assert set(store["data"]["accepted_by"]) == {"a", "me"}


def test_match_respond_403_for_non_participant(monkeypatch):
    _match_db(monkeypatch, {"uids": ["a", "b"], "status": "scored"})
    resp = client.post(
        "/match/a__b/respond",
        headers=_auth(monkeypatch, uid="stranger"),
        json={"response": "accept"},
    )
    assert resp.status_code == 403


def test_profile_share_posts_a_shared_profile_message(monkeypatch):
    seen = {}

    def _post(db, sender, other, mtype, body):
        seen.update(sender=sender, other=other, mtype=mtype, body=body)
        return "m1"

    monkeypatch.setattr(main.dm_ops, "post_message", _post)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post("/profile/share", headers=_auth(monkeypatch, uid="me"),
                       json={"shared_uid": "carol", "thread_with": "bob"})
    assert resp.json() == {"ok": True, "message_id": "m1"}
    assert seen == {"sender": "me", "other": "bob",
                    "mtype": "shared_profile", "body": "carol"}


# --- /explore/unlike -------------------------------------------------------


class _UnlikeDb:
    """Fake Firestore for the unlike handler: records like-doc deletes and
    serves / captures the one matches/{id} doc."""

    def __init__(self, match_doc=None):
        self.deleted = []
        self.match_doc = match_doc
        self.match_writes = {}

    def collection(self, name):
        return _UnlikeCollection(self, name)


class _UnlikeCollection:
    def __init__(self, db, name):
        self.db = db
        self.name = name

    def document(self, _id):
        return _UnlikeDoc(self.db, self.name)


class _UnlikeDoc:
    def __init__(self, db, col_name):
        self.db = db
        self.col_name = col_name

    def collection(self, name):
        return _UnlikeCollection(self.db, name)

    def delete(self):
        self.db.deleted.append(self.col_name)

    def get(self):
        doc = self.db.match_doc

        class _S:
            exists = doc is not None

            @staticmethod
            def to_dict():
                return dict(doc) if doc else None

        return _S()

    def set(self, payload, merge=False):
        self.db.match_writes.update(payload)


def test_explore_unlike_deletes_the_like_and_walks_back_a_mutual_match(
    monkeypatch,
):
    db = _UnlikeDb(match_doc={"status": "mutual_interest", "score": 0.4})
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")

    resp = client.post(
        "/explore/unlike",
        headers=_auth(monkeypatch, uid="me"),
        json={"other_uid": "them"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert "likes" in db.deleted
    # A scored pair walks back to "scored", not off the board entirely.
    assert db.match_writes["status"] == "scored"


def test_explore_unlike_walks_an_unscored_mutual_to_unmatched(monkeypatch):
    db = _UnlikeDb(match_doc={"status": "mutual_interest"})
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")

    resp = client.post(
        "/explore/unlike",
        headers=_auth(monkeypatch, uid="me"),
        json={"other_uid": "them"},
    )
    assert resp.status_code == 200
    assert db.match_writes["status"] == "unmatched"


def test_explore_unlike_is_a_noop_when_nothing_is_liked(monkeypatch):
    db = _UnlikeDb(match_doc=None)
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")

    resp = client.post(
        "/explore/unlike",
        headers=_auth(monkeypatch, uid="me"),
        json={"other_uid": "them"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert "likes" in db.deleted  # delete of a missing doc is harmless
    assert db.match_writes == {}  # no match doc -> nothing walked back


def test_explore_unlike_rejects_self(monkeypatch):
    resp = client.post(
        "/explore/unlike",
        headers=_auth(monkeypatch, uid="me"),
        json={"other_uid": "me"},
    )
    assert resp.status_code == 400
