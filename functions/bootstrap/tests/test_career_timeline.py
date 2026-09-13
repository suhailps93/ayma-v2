import asyncio

import career_timeline
import gemini


# --- fake Firestore (same shape as tests/test_story.py's) -------------------


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = None if data is None else dict(data)

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store = store
        self.key = key

    def get(self):
        return _Snap(self.key[-1], self.store.docs.get(self.key))

    def set(self, payload, merge=False):
        cur = dict(self.store.docs.get(self.key) or {}) if merge else {}
        cur.update(payload)
        self.store.docs[self.key] = cur

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store = store
        self.key = key

    def document(self, doc_id=None):
        if doc_id is None:
            self.store.counter += 1
            doc_id = f"auto{self.store.counter:04d}"
        return _DocRef(self.store, self.key + (doc_id,))

    def stream(self):
        d = len(self.key)
        for k, v in list(self.store.docs.items()):
            if len(k) == d + 1 and k[:d] == self.key and v is not None:
                yield _Snap(k[-1], v)


class FakeDb:
    def __init__(self):
        self.docs = {}
        self.counter = 0

    def collection(self, name):
        return _CollRef(self, (name,))


def _page(db, uid, page_id, **data):
    db.docs[("users", uid, "wiki_pages", page_id)] = data


def _run(coro):
    return asyncio.run(coro)


def _fake_extraction(overall, entries):
    async def _fn(contents, system_prompt, response_schema=None, **kw):
        return {"overall_confidence": overall, "entries": entries}

    return _fn


_DECENT_ENTRIES = [
    {
        "kind": "work", "org": "Figure AI",
        "title_or_degree": "Software Integration Engineer",
        "start": "2025", "end": "Present", "confidence": "high",
    },
    {
        "kind": "education", "org": "Northwestern University",
        "title_or_degree": "M.S. in Robotics",
        "start": "2020", "end": "2022", "confidence": "medium",
    },
]


# --- extraction + confidence gate ---------------------------------------


def test_extract_shows_timeline_when_every_entry_is_decent(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="I build robots at Figure AI.")
    monkeypatch.setattr(
        gemini, "generate_json", _fake_extraction("high", _DECENT_ENTRIES)
    )

    result = _run(career_timeline.extract(db, "u1"))
    assert result["show_timeline"] is True
    assert result["overall_confidence"] == "high"
    assert len(result["entries"]) == 2
    assert all(e["id"] for e in result["entries"])
    # persisted on the career page, not just returned
    persisted = db.docs[("users", "u1", "wiki_pages", "career")][
        career_timeline.FIELD_TIMELINE
    ]
    assert persisted["show_timeline"] is True


def test_extract_falls_back_to_prose_when_any_entry_is_low_confidence(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public", ai_body="x")
    shaky = _DECENT_ENTRIES[:1] + [
        {**_DECENT_ENTRIES[1], "confidence": "low"},
    ]
    monkeypatch.setattr(gemini, "generate_json", _fake_extraction("high", shaky))

    result = _run(career_timeline.extract(db, "u1"))
    assert result["show_timeline"] is False


def test_extract_falls_back_to_prose_when_overall_confidence_is_low(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public", ai_body="x")
    monkeypatch.setattr(
        gemini, "generate_json", _fake_extraction("low", _DECENT_ENTRIES)
    )

    result = _run(career_timeline.extract(db, "u1"))
    assert result["show_timeline"] is False


def test_extract_with_no_entries_never_shows_a_timeline(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public", ai_body="x")
    monkeypatch.setattr(gemini, "generate_json", _fake_extraction("none", []))

    result = _run(career_timeline.extract(db, "u1"))
    assert result["show_timeline"] is False
    assert result["entries"] == []


def test_get_or_build_timeline_builds_once_then_caches(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public", ai_body="x")
    calls = {"n": 0}

    async def _counting(contents, system_prompt, response_schema=None, **kw):
        calls["n"] += 1
        return {"overall_confidence": "high", "entries": _DECENT_ENTRIES}

    monkeypatch.setattr(gemini, "generate_json", _counting)

    first = _run(career_timeline.get_or_build_timeline(db, "u1"))
    second = _run(career_timeline.get_or_build_timeline(db, "u1"))
    assert calls["n"] == 1  # only built once
    assert first["show_timeline"] is True
    assert second["entries"] == first["entries"]
    assert second["linkedin_url"] == ""


# --- chat-editable, one entry at a time ---------------------------------


def _seed_timeline(db, uid, entries, overall="high"):
    _page(db, uid, "career", page_type="career", visibility="public", ai_body="x")
    for e in entries:
        e["id"] = career_timeline._entry_id(e)
    career_timeline.story._pages_col(db, uid).document("career").set(
        {
            career_timeline.FIELD_TIMELINE: {
                "entries": entries,
                "overall_confidence": overall,
                "show_timeline": True,
                "updated_at": 0,
            }
        },
        merge=True,
    )
    return entries[0]["id"]


def test_edit_entry_updates_only_the_given_fields():
    db = FakeDb()
    entries = [dict(e) for e in _DECENT_ENTRIES]
    eid = _seed_timeline(db, "u1", entries)

    msg = career_timeline.edit_entry(db, "u1", eid, {"end": "2024"})
    assert "updated" in msg
    saved = db.docs[("users", "u1", "wiki_pages", "career")][
        career_timeline.FIELD_TIMELINE
    ]
    updated = next(e for e in saved["entries"] if e["id"] == eid)
    assert updated["end"] == "2024"
    assert updated["org"] == "Figure AI"  # untouched


def test_edit_entry_unknown_id_reports_not_found():
    db = FakeDb()
    entries = [dict(e) for e in _DECENT_ENTRIES]
    _seed_timeline(db, "u1", entries)
    assert "couldn't find" in career_timeline.edit_entry(
        db, "u1", "nope", {"end": "2024"}
    )


def test_edit_entry_with_no_timeline_entry_id_asks_for_focus():
    db = FakeDb()
    assert "no timeline entry" in career_timeline.edit_entry(db, "u1", "", {"end": "x"})


def test_delete_entry_removes_it_and_regates_confidence():
    db = FakeDb()
    entries = [dict(e) for e in _DECENT_ENTRIES]
    eid = _seed_timeline(db, "u1", entries)

    msg = career_timeline.delete_entry(db, "u1", eid)
    assert "removed" in msg
    saved = db.docs[("users", "u1", "wiki_pages", "career")][
        career_timeline.FIELD_TIMELINE
    ]
    assert len(saved["entries"]) == 1
    assert all(e["id"] != eid for e in saved["entries"])
    # one decent entry left -> still shows
    assert saved["show_timeline"] is True


def test_delete_last_entry_hides_the_timeline():
    db = FakeDb()
    entries = [dict(_DECENT_ENTRIES[0])]
    eid = _seed_timeline(db, "u1", entries)

    career_timeline.delete_entry(db, "u1", eid)
    saved = db.docs[("users", "u1", "wiki_pages", "career")][
        career_timeline.FIELD_TIMELINE
    ]
    assert saved["entries"] == []
    assert saved["show_timeline"] is False


# --- LinkedIn URL: user-given, never scraped -----------------------------


def test_is_linkedin_url_accepts_only_linkedin_links():
    assert career_timeline.is_linkedin_url("https://www.linkedin.com/in/jane-doe/")
    assert career_timeline.is_linkedin_url("https://linkedin.com/in/jane-doe/")
    assert not career_timeline.is_linkedin_url("https://example.com/in/jane-doe/")
    assert not career_timeline.is_linkedin_url("")


def test_set_linkedin_url_rejects_a_non_linkedin_link():
    db = FakeDb()
    try:
        career_timeline.set_linkedin_url(db, "u1", "https://example.com/x")
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_set_and_get_linkedin_url_round_trip():
    db = FakeDb()
    url = career_timeline.set_linkedin_url(
        db, "u1", "https://www.linkedin.com/in/jane-doe/"
    )
    assert url == "https://www.linkedin.com/in/jane-doe/"
    assert career_timeline.get_linkedin_url(db, "u1") == url


def test_get_linkedin_url_defaults_to_empty():
    db = FakeDb()
    assert career_timeline.get_linkedin_url(db, "u1") == ""
