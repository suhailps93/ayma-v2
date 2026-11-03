"""``find_fact_source`` — § fact-source-of-truth, 2026-09-21 (founder bug
report: asked Ayma "where did you get this from" about his child's name/
daycare and got a generic non-answer). Covers the provenance sources it
aggregates: profile-field, questionnaire, wiki source_log, deep-dive finds
(facts, links, social profiles, photos)."""

import json

import skills
from skills import fact_source


# --- a tiny path-keyed Firestore fake (same shape as test_wiki_ingest.py) ---


class _Snap:
    def __init__(self, key, data):
        self.id = key[-1]
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))

    def get(self):
        return _Snap(self.key, self.store.docs.get(self.key))


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _DocRef(self.store, self.key + (doc_id,))

    def stream(self):
        d = len(self.key)
        seen = set()
        for k in list(self.store.docs.keys()):
            if len(k) > d and k[:d] == self.key and k[d] not in seen:
                seen.add(k[d])
                child = self.key + (k[d],)
                yield _Snap(child, self.store.docs.get(child))


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def collection(self, name):
        return _CollRef(self, (name,))


def _tool(db):
    return skills.make_session_tool_fns(db, "u1")["find_fact_source"]


def test_registered_in_the_shared_registry():
    assert "find_fact_source" in {s.name for s in skills.all_skills()}
    assert "find_fact_source" in {
        d["name"] for d in skills.session_tool_declarations()
    }


def test_empty_query_asks_for_a_description():
    db = FakeDb()
    assert "description" in _tool(db)("").lower()


def test_no_match_returns_an_empty_list_not_a_guess():
    db = FakeDb({("users", "u1", "profile", "main"): {}})
    out = json.loads(_tool(db)("something totally unrelated xyz"))
    assert out == {"matches": []}


def test_finds_a_chat_profile_field_match():
    db = FakeDb({
        ("users", "u1", "profile", "main"): {
            "phone": "+15551234567",
            "provenance": {
                "phone": {
                    "source_type": "chat",
                    "quote": "my number is 555-123-4567",
                    "session_id": "sess-1",
                    "turn_index": 4,
                    "at": "2026-09-10T10:00:00+00:00",
                }
            },
        }
    })
    out = json.loads(_tool(db)("phone number"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["type"] == "chat"
    assert m["exact"] is True
    assert m["quote"] == "my number is 555-123-4567"


def test_finds_a_questionnaire_match_with_provenance():
    db = FakeDb({
        ("users", "u1", "questionnaire", "alcohol_consumption"): {
            "value": "Rare Social",
            "provenance": {
                "source_type": "chat",
                "quote": "I drink socially, rarely",
                "session_id": "sess-2",
                "turn_index": 1,
                "at": "2026-09-01T00:00:00+00:00",
            },
        }
    })
    out = json.loads(_tool(db)("alcohol drinking habits"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["exact"] is True
    assert m["quote"] == "I drink socially, rarely"


def test_finds_a_questionnaire_match_without_provenance_marked_inexact():
    db = FakeDb({
        ("users", "u1", "questionnaire", "alcohol_consumption"): {
            "value": "Rare Social",
        }
    })
    out = json.loads(_tool(db)("alcohol drinking habits"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["exact"] is False
    assert m["current_value"] == "Rare Social"


def test_finds_a_wiki_source_log_match():
    """The exact bug report scenario: the Family page's ai_body has a
    verbatim excerpt on file — the fix that answers "where did you get
    this" instead of a generic reply."""
    db = FakeDb({
        ("users", "u1", "wiki_pages", "family"): {
            "ai_body": "His son Yahya goes to Sunshine Daycare.",
            "source_log": [
                {
                    "session_id": "sess-fam",
                    "excerpt": "User: my son Yahya goes to Sunshine Daycare",
                    "at": "2026-08-14T09:00:00+00:00",
                }
            ],
        }
    })
    out = json.loads(_tool(db)("my son's name and daycare"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["type"] == "chat"
    assert m["exact"] is True
    assert "Yahya" in m["quote"]
    assert m["when"] == "2026-08-14T09:00:00+00:00"


def test_finds_a_deep_dive_web_search_match():
    db = FakeDb({
        ("users", "u1", "deep_dives", "uid_target1"): {
            "digest": {
                "name": "Jordan Rivers",
                "facts": [
                    {
                        "claim": "Jordan works as a designer at Acme Corp",
                        "category": "work",
                        "source_url": "https://acme.example.com/team/jordan",
                        "confidence": "high",
                    }
                ],
            },
            "created_at": "2026-07-01T00:00:00+00:00",
        }
    })
    out = json.loads(_tool(db)("Jordan's job at Acme"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["type"] == "web_search"
    assert m["exact"] is True
    assert m["url"] == "https://acme.example.com/team/jordan"
    assert "designer" in m["quote"]


def test_finds_a_deep_dive_link_match():
    # A plain web-link find (J7: the PERSONAL WEBSITE find) is traceable too —
    # not just fact claims.
    db = FakeDb({
        ("users", "u1", "deep_dives", "uid_target1"): {
            "digest": {
                "name": "Jordan Rivers",
                "facts": [],
                "links": [
                    {
                        "url": "https://jordanrivers.example.com",
                        "title": "Personal Website",
                    }
                ],
            },
            "created_at": "2026-07-01T00:00:00+00:00",
        }
    })
    out = json.loads(_tool(db)("personal website source link"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["type"] == "web_search"
    assert m["exact"] is True
    assert m["url"] == "https://jordanrivers.example.com"


def test_finds_a_deep_dive_social_match():
    db = FakeDb({
        ("users", "u1", "deep_dives", "uid_target1"): {
            "digest": {
                "name": "Jordan Rivers",
                "facts": [],
                "social_handles": [
                    {
                        "platform": "instagram",
                        "handle": "jorivers",
                        "url": "https://instagram.com/jorivers",
                    }
                ],
            },
            "created_at": "2026-07-01T00:00:00+00:00",
        }
    })
    out = json.loads(_tool(db)("jorivers instagram profile"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["type"] == "web_search"
    assert m["exact"] is True
    assert m["url"] == "https://instagram.com/jorivers"


def test_finds_a_deep_dive_photo_match_by_its_source_page():
    # A "photos found online" thumbnail traces to the page it was found on.
    db = FakeDb({
        ("users", "u1", "deep_dives", "uid_target1"): {
            "digest": {
                "name": "Jordan Rivers",
                "facts": [],
                "web_images": [
                    {
                        "url": "https://cdn.example.com/jordan.jpg",
                        "source_page": "https://blog.example.com/team-post",
                    }
                ],
            },
            "created_at": "2026-07-01T00:00:00+00:00",
        }
    })
    out = json.loads(_tool(db)("blog team photo"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["type"] == "web_search"
    assert m["exact"] is True
    assert m["url"] == "https://blog.example.com/team-post"


def test_finds_a_face_body_correction_match():
    db = FakeDb({
        ("users", "u1", "appearance_reports", "current"): {
            "face": {"verdict": "...", "user_correction": "my nose isn't crooked, that photo angle is bad"},
        }
    })
    out = json.loads(_tool(db)("my nose"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["type"] == "chat"
    assert m["exact"] is True
    assert "crooked" in m["quote"]


def test_finds_an_attribute_correction_in_finding_history():
    db = FakeDb({
        ("users", "u1", "appearance_reports", "current"): {
            "finding_history": {
                "eye_color": [
                    {
                        "value": "brown",
                        "reason": "you corrected this: they're actually hazel not brown",
                        "changed_at_ms": 1758000000000,
                    }
                ]
            },
        }
    })
    out = json.loads(_tool(db)("eye color"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["exact"] is True
    assert "hazel" in m["quote"]
    assert m["when"]


def test_results_are_capped_and_ranked_by_overlap():
    docs = {("users", "u1", "profile", "main"): {}}
    for i in range(10):
        docs[("users", "u1", "wiki_pages", f"page{i}")] = {
            "ai_body": "x",
            "source_log": [
                {"session_id": "s", "excerpt": "bouldering rocks", "at": "T"}
            ],
        }
    db = FakeDb(docs)
    out = json.loads(_tool(db)("bouldering"))
    assert len(out["matches"]) == fact_source._MAX_MATCHES


# --- #28: provenance paraphrases resolve to the stored source ---------------
# Follow-up to the Nov 2 founder retest: natural phrasings ("where did you get
# this information from") must behave like the keyword "source" ask. Two
# halves: (a) content-bearing paraphrases match as usual; (b) a BARE
# provenance question in a sheet (no content tokens — "where's this from")
# resolves deictically to the FOCUSED item's stored source instead of coming
# back empty.

_JUSTABOT_URL = "https://apps.apple.com/se/app/justabot/id6453466936?l=en-GB"
_JUSTABOT_SUMMARY = (
    "In addition to his robotics engineering background, he is the developer "
    "of the iOS application justaBOT."
)
_JUSTABOT_FACTS = [
    {"id": "aaa111", "claim": "Works as a robotics engineer at Acme",
     "category": "work", "source_url": "https://acme.example.com/team/dana"},
    {"id": "bbb222", "claim": "Developer of the iOS app justaBOT",
     "category": "projects", "source_url": _JUSTABOT_URL},
]


def _dive_db(facts=None):
    return FakeDb({
        ("users", "u1", "deep_dives", "uid_target1"): {
            "digest": {
                "name": "Dana Reis",
                "summary": _JUSTABOT_SUMMARY,
                "facts": list(_JUSTABOT_FACTS) if facts is None else facts,
            },
            "created_at": "2026-07-01T00:00:00+00:00",
        }
    })


def _focused_tool(db, target="summary"):
    return skills.make_session_tool_fns(
        db, "u1", deep_dive_ctx={"report_id": "uid_target1", "target": target}
    )["find_fact_source"]


def test_provenance_paraphrase_naming_the_fact_returns_its_url():
    # Main-chat path: the model passes the fact (possibly wrapped in the
    # question's own words) — paraphrase boilerplate must not break matching.
    db = _dive_db()
    for query in (
        "where's this justaBOT app from?",
        "who says I built justaBOT",
        "what's this justaBOT claim based on",
    ):
        out = json.loads(_tool(db)(query))
        assert out["matches"], query
        assert out["matches"][0]["url"] == _JUSTABOT_URL, query


def test_bare_provenance_question_with_sheet_focus_returns_the_focused_source():
    # Sheet path via the tool: "where did you get this information from" has
    # no content tokens ({information} matches nothing) and "where's this
    # from" has NO tokens at all — both resolve to the focused summary's
    # backing-fact URL instead of coming back empty.
    db = _dive_db()
    tool = _focused_tool(db)
    for query in (
        "where did you get this information from",
        "where did you get this information from?",
        "where's this from",
    ):
        out = json.loads(tool(query))
        assert out["matches"], query
        first = out["matches"][0]
        assert first["url"] == _JUSTABOT_URL, query
        assert first["exact"] is True, query


def test_repeated_focused_provenance_ask_is_stable():
    db = _dive_db()
    tool = _focused_tool(db)
    first = tool("where did you get this information from?")
    assert json.loads(first)["matches"][0]["url"] == _JUSTABOT_URL
    assert tool("where did you get this information from?") == first


def test_focused_item_without_source_stays_honest():
    # Focused summary, but nothing stored behind it: no invented URL.
    db = _dive_db(facts=[
        {"id": "aaa111", "claim": "Lives in Austin", "category": "other"}
    ])
    out = json.loads(_focused_tool(db)("where did you get this information from"))
    assert out == {"matches": []}


def test_content_query_with_focus_keeps_normal_ranking():
    # A content query that merely MENTIONS "source link" is not a provenance
    # question — normal keyword ranking applies, no focused-item prepend.
    docs = _dive_db().docs
    docs[("users", "u1", "deep_dives", "uid_target1")]["digest"]["links"] = [
        {"url": "https://danareis.example.com", "title": "Personal Website"}
    ]
    db = FakeDb(docs)
    out = json.loads(_focused_tool(db)("personal website source link"))
    assert out["matches"][0]["url"] == "https://danareis.example.com"


def test_provenance_query_naming_other_content_keeps_both_matches():
    # In a sheet, deictic "this" binds to the focused item — it leads — but a
    # content-named match stays in the list for the model to disambiguate.
    db = _dive_db()
    out = json.loads(
        _focused_tool(db)("where did you get the Acme job from")
    )
    urls = [m["url"] for m in out["matches"]]
    assert urls[0] == _JUSTABOT_URL
    assert "https://acme.example.com/team/dana" in urls


def test_tool_description_names_provenance_paraphrases():
    # The declaration description is the function-calling routing signal: it
    # must name natural phrasings, not just "where did you get that".
    assert "where's this from" in fact_source.DESCRIPTION
    assert "find_fact_source" in fact_source.DECLARATION["name"]
