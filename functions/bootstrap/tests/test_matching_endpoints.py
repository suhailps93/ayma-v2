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


def test_check_compatibility_writes_a_match_doc(monkeypatch):
    async def _fake_score(db, a, b):
        return {
            "score": 0.62,
            "raw_score": 0.62,
            "user_explanation": {a: "for you", b: "for them"},
            "ai_explanation": "private",
            "trust_flags": {a: [], b: []},
        }

    monkeypatch.setattr(main.matching_skill, "score_pair", _fake_score)

    writes = {}

    class _Ref:
        def get(self):
            class _S:
                exists = False

            return _S()

        def set(self, payload, merge=False):
            writes.update(payload)

    class _Db:
        def collection(self, name):
            assert name == "matches"
            return self

        def document(self, mid):
            writes["_id"] = mid
            return _Ref()

    monkeypatch.setattr(main, "get_db", lambda: _Db())
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")

    resp = client.post(
        "/check-compatibility",
        headers=_auth(monkeypatch, uid="bbb"),
        json={"other_uid": "aaa"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["match_id"] == "aaa__bbb"
    assert body["score"] == 0.62
    assert writes["uids"] == ["aaa", "bbb"]
    assert writes["status"] == "scored"
    assert writes["user_explanation"] == {"bbb": "for you", "aaa": "for them"}


def test_block_writes_a_block_doc(monkeypatch):
    writes = {}

    class _Ref:
        def set(self, payload):
            writes.update(payload)

    class _Db:
        def collection(self, name):
            assert name == "blocks"
            return self

        def document(self, bid):
            writes["_id"] = bid
            return _Ref()

    monkeypatch.setattr(main, "get_db", lambda: _Db())
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")
    resp = client.post(
        "/block", headers=_auth(monkeypatch, uid="me"),
        json={"blocked_uid": "them"},
    )
    assert resp.status_code == 200
    assert writes["_id"] == "me_them"
    assert writes["blocker"] == "me" and writes["blocked"] == "them"


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
