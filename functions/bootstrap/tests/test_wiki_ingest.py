import asyncio

import gemini
import token_ledger
import wiki_ingest
from transcript import Turn


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data or {})


class _DocRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def get(self):
        return _Snap(self._key[-1], self._store.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = self._store.docs.get(self._key, {}) if merge else {}
        cur.update(payload)
        self._store.docs[self._key] = cur
        self._store.writes.append((self._key, payload, merge))

    def collection(self, name):
        return _CollRef(self._store, self._key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def document(self, name):
        return _DocRef(self._store, self._key + (name,))

    def stream(self):
        depth = len(self._key)
        for key, data in self._store.docs.items():
            if len(key) == depth + 1 and key[:depth] == self._key:
                yield _Snap(key[-1], data)


class FakeDb:
    def __init__(self):
        self.docs = {}
        self.writes = []

    def collection(self, name):
        return _CollRef(self, (name,))


def _seed_page(db, uid, page_id, data):
    db.docs[("users", uid, "wiki_pages", page_id)] = data


def _run(coro):
    return asyncio.run(coro)


def test_ingest_creates_a_page_from_a_hobby_conversation(monkeypatch):
    db = FakeDb()

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        assert "bouldering" in contents  # the conversation reached the model
        return {
            "pages": [
                {
                    "page_id": "bouldering",
                    "page_type": "interests",
                    "visibility": "public",
                    "ai_body": "They boulder indoors twice a week and love it.",
                    "links": ["lifestyle"],
                    "frontmatter": {"sport": "bouldering"},
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    written = _run(
        wiki_ingest.ingest(
            db,
            "u1",
            "sess-1",
            [
                Turn("user", "my main hobby is bouldering, twice a week"),
                Turn("ayma", "indoor or real rock?"),
                Turn("user", "indoor mostly"),
            ],
        )
    )

    assert written == 1
    page = db.docs[("users", "u1", "wiki_pages", "bouldering")]
    assert page["ai_body"].startswith("They boulder indoors")
    assert page["visibility"] == "public"
    assert page["page_type"] == "interests"
    assert page["links"] == ["lifestyle"]
    assert page["frontmatter"] == {"sport": "bouldering"}
    assert "created_at" in page and "updated_at" in page


def test_ingest_rewrites_an_existing_page_and_keeps_created_at(monkeypatch):
    db = FakeDb()
    _seed_page(
        db,
        "u1",
        "career",
        {"ai_body": "Works in marketing.", "page_type": "career",
         "created_at": "ORIGINAL"},
    )

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        assert "Works in marketing." in contents  # existing body was shown
        return {
            "pages": [
                {
                    "page_id": "career",
                    "page_type": "career",
                    "visibility": "private",
                    "ai_body": "Marketing lead at a fintech; wants to move into"
                    " product.",
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    written = _run(
        wiki_ingest.ingest(
            db, "u1", "sess-2", [Turn("user", "actually I lead the team now")]
        )
    )

    assert written == 1
    page = db.docs[("users", "u1", "wiki_pages", "career")]
    assert "product" in page["ai_body"]
    assert page["created_at"] == "ORIGINAL"  # not overwritten on rewrite


def test_ingest_keeps_the_users_own_visibility_choice(monkeypatch):
    db = FakeDb()
    _seed_page(
        db, "u1", "career",
        {"ai_body": "Old.", "page_type": "career", "created_at": "ORIG",
         "visibility": "private", "user_updated_at": "USER-SET-IT"},
    )

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        return {"pages": [{
            "page_id": "career", "page_type": "career",
            "visibility": "public",  # model wants public; user chose private
            "ai_body": "New body.",
        }]}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    _run(wiki_ingest.ingest(db, "u1", "s", [Turn("user", "hi")]))

    page = db.docs[("users", "u1", "wiki_pages", "career")]
    assert page["ai_body"] == "New body."  # body still refreshed
    assert page["visibility"] == "private"  # user's choice preserved


def test_ingest_skips_invalid_ops(monkeypatch):
    db = FakeDb()

    async def _fake_json(*a, **k):
        return {
            "pages": [
                {"page_id": "Bad Id", "page_type": "career",
                 "visibility": "private", "ai_body": "x"},
                {"page_id": "ok", "page_type": "not-a-type",
                 "visibility": "private", "ai_body": "x"},
                {"page_id": "ok2", "page_type": "career",
                 "visibility": "loud", "ai_body": "x"},
                {"page_id": "ok3", "page_type": "career",
                 "visibility": "private", "ai_body": "   "},
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    written = _run(wiki_ingest.ingest(db, "u1", "s", [Turn("user", "hi")]))
    assert written == 0
    assert db.writes == []


def test_ingest_bypasses_the_credit_gate_but_still_records_usage(monkeypatch):
    """Founder directive (2026-09-20): wiki ingest must run and save real
    profile data even when the user is completely out of credits — not
    deferred to a maybe-later backfill. ``ingest`` passes
    ``enforce_cap=False`` to ``gemini.generate_json`` (the same escape hatch
    dm_moderation/persona_evolution/completeness/deep_dive_images already
    use), which skips the pre-call ``TokenCapExceeded`` check but still
    records the real spend via ``token_ledger`` exactly like any other call —
    proven here by simulating an exhausted credit balance and confirming
    ingest still runs to completion."""
    db = FakeDb()
    seen = {}

    async def _fake_json_honoring_the_real_gate(
        contents, system_prompt, response_schema=None, enforce_cap=True, **kw
    ):
        seen.update(kw)
        seen["enforce_cap"] = enforce_cap
        if enforce_cap:
            token_ledger.check(kw.get("uid"))  # would raise for a broke user
        return {
            "pages": [
                {
                    "page_id": "career",
                    "page_type": "career",
                    "visibility": "private",
                    "ai_body": "Leads a small team.",
                }
            ]
        }

    def _out_of_credits(_uid):
        raise token_ledger.TokenCapExceeded("out of credits")

    monkeypatch.setattr(gemini, "generate_json", _fake_json_honoring_the_real_gate)
    monkeypatch.setattr(token_ledger, "check", _out_of_credits)

    written = _run(
        wiki_ingest.ingest(db, "u1", "s", [Turn("user", "I lead the team now")])
    )

    assert written == 1  # ran and saved data despite the simulated credit cap
    page = db.docs[("users", "u1", "wiki_pages", "career")]
    assert page["ai_body"] == "Leads a small team."
    assert seen.get("feature") == "wiki"
    assert seen.get("enforce_cap") is False  # explicitly exempt, not default


def test_ingest_prompt_forbids_pronoun_inference():
    """Founder report, 2026-09-20: a public Identity section rendered "Goes by
    Dillu (she/her)" with a pronoun the user never stated. The Identity page's
    `ai_body` is free-text narrative authored by Gemini (no template, no
    structured pronoun field) from wiki_ingest.md + wiki_schema.json's
    `identity` page description — both of which reach the model verbatim via
    `_build_contents`. This is a regression guard on the actual instructions
    the model receives, not the model's behaviour (which can't be asserted
    deterministically): it must explicitly forbid guessing a pronoun from a
    name/photo, not just carry the old generic "never infer" rule.
    """
    prompt = wiki_ingest.load_ingest_prompt().lower()
    assert "pronoun" in prompt
    assert "never guess" in prompt or "never infer" in prompt
    assert "name" in prompt and "photo" in prompt

    # The page_types block (built from wiki_schema.json, fed into the same
    # prompt contents) must carry the same caveat next to "pronouns" rather
    # than presenting it as an always-expected field.
    contents = wiki_ingest._build_contents([], []).lower()
    assert "pronouns (only if the user explicitly stated" in contents


def test_ingest_no_turns_is_a_noop(monkeypatch):
    db = FakeDb()
    called = False

    async def _fake_json(*a, **k):
        nonlocal called
        called = True
        return {"pages": []}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    assert _run(wiki_ingest.ingest(db, "u1", "s", [])) == 0
    assert called is False


def test_ingest_accepts_an_interactions_page_and_forces_it_ai_only(monkeypatch):
    """A transcript where Ayma reports on another person must not create
    identity/career pages about that person, but MAY record a one-line
    `interactions` note about the user's reaction — and that page is forced
    server-side to `ai_only` (Ayma's own behavioural inference, never shown
    to the user by default) regardless of what visibility the model
    requested, and still reaches Ayma via read_wiki_context."""
    import wiki_query

    db = FakeDb()

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        # The prompt teaches this separation.
        assert "ACCOUNT HOLDER" in system_prompt
        return {
            "pages": [
                {
                    "page_id": "interactions",
                    "page_type": "interactions",
                    # A misbehaving/older model response might still ask for
                    # `private` (or anything else) — the server must not
                    # honour it for this page_type.
                    "visibility": "private",
                    "ai_body": (
                        "Things the user did with Ayma, newest first.\n\n"
                        "- 2026-09-10 — deep-dived Jordan (designer, Berlin); "
                        "lit up about the creative-career angle -> leans toward "
                        "artistic partners"
                    ),
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    written = _run(
        wiki_ingest.ingest(
            db,
            "u1",
            "sess-x",
            [
                Turn("user", "what did you find on Jordan?"),
                Turn("ayma", "Jordan is a designer in Berlin, at a studio..."),
                Turn("user", "oh nice, I love that he's a creative"),
            ],
        )
    )

    assert written == 1
    keys = {
        k[-1] for k in db.docs if k[:3] == ("users", "u1", "wiki_pages")
    }
    assert keys == {"interactions"}  # no identity/career page about Jordan
    page = db.docs[("users", "u1", "wiki_pages", "interactions")]
    assert page["page_type"] == "interactions"
    assert page["visibility"] == "ai_only"  # forced, not the model's "private"

    ctx = wiki_query.read_wiki_context(db, "u1")
    assert "deep-dived Jordan" in ctx  # ai_only still feeds Ayma's context


def test_write_page_forces_interactions_ai_only_even_over_user_updated_at(
    monkeypatch,
):
    """Belt-and-suspenders: even if a page somehow already carries
    `user_updated_at` with a public/private visibility (the "user's own
    choice wins" carry-forward), an `interactions` page must still end up
    `ai_only` — this page_type is never user-editable-to-public in the first
    place, and the override must not accidentally resurrect an old value."""
    db = FakeDb()
    _seed_page(
        db,
        "u1",
        "interactions",
        {
            "ai_body": "old body",
            "visibility": "public",
            "page_type": "interactions",
            "user_updated_at": "2026-01-01T00:00:00Z",
        },
    )

    async def _fake_json(*a, **k):
        return {
            "pages": [
                {
                    "page_id": "interactions",
                    "page_type": "interactions",
                    "visibility": "public",
                    "ai_body": "new body",
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    written = _run(wiki_ingest.ingest(db, "u1", "s", [Turn("user", "hi")]))

    assert written == 1
    page = db.docs[("users", "u1", "wiki_pages", "interactions")]
    assert page["visibility"] == "ai_only"


def test_ingest_forces_a_steering_page_ai_only_regardless_of_model_visibility(
    monkeypatch,
):
    """Same treatment as `interactions` (founder confirmation, 2026-09-13):
    `steering` is a standing instruction about the user, not shown to them by
    default, forced server-side regardless of what the model requested."""
    db = FakeDb()

    async def _fake_json(*a, **k):
        return {
            "pages": [
                {
                    "page_id": "steering",
                    "page_type": "steering",
                    "visibility": "private",
                    "ai_body": "- keep questions short",
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    written = _run(wiki_ingest.ingest(db, "u1", "s", [Turn("user", "hi")]))

    assert written == 1
    page = db.docs[("users", "u1", "wiki_pages", "steering")]
    assert page["visibility"] == "ai_only"


def test_ingest_still_accepts_an_explicit_ai_only_visibility(monkeypatch):
    """`ai_only` remains a legal value in the schema (reserved for content
    Ayma infers on her own) — the pipeline still writes it through unchanged
    and it still feeds read_wiki_context."""
    import wiki_query

    db = FakeDb()

    async def _fake_json(*a, **k):
        return {
            "pages": [
                {
                    "page_id": "sensitive",
                    "page_type": "sensitive",
                    "visibility": "ai_only",
                    "ai_body": "Ayma's own private note about the user.",
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    written = _run(wiki_ingest.ingest(db, "u1", "s", [Turn("user", "hi")]))

    assert written == 1
    page = db.docs[("users", "u1", "wiki_pages", "sensitive")]
    assert page["visibility"] == "ai_only"
    ctx = wiki_query.read_wiki_context(db, "u1")
    assert "Ayma's own private note" in ctx


def test_prompt_asks_for_the_interaction_pattern():
    p = wiki_ingest.load_ingest_prompt()
    assert "how the user engages with Ayma herself" in p
    assert "communication style" in p
    assert 'Write to `steering`' in p


def test_ingest_window_carries_the_users_turns_verbatim(monkeypatch):
    """TASK 2 check: the model input is the user's turns verbatim, not a
    summary — so the interaction pattern is observable."""
    db = FakeDb()
    seen = {}

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        seen["contents"] = contents
        return {"pages": []}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    _run(
        wiki_ingest.ingest(
            db, "u1", "s",
            [
                Turn("user", "stop asking me so many questions, just listen"),
                Turn("ayma", "understood."),
            ],
        )
    )
    assert "stop asking me so many questions, just listen" in seen["contents"]
    assert "User: stop asking me so many questions" in seen["contents"]


# --- ingest_or_defer ---------------------------------------------------------
#
# Root cause (real conversation, uid iWhWjiWhEpU7iyu9B9vy7GlT0PD2, 2026-09-20):
# a voice session's shutdown hook (agent.py) used to persist the raw
# transcript but never attempt a wiki write at all — so a user's real answer
# to a questionnaire question, given right before their credits ran out mid
# session, was never captured anywhere: not written to the wiki, and not even
# flagged for the nightly backfill sweep the way the text/DM paths already
# were on a credit-cap failure. `ingest_or_defer` is the one function both
# paths now share, so any caller that reaches it gets the same safety net.


def test_ingest_or_defer_behaves_like_ingest_on_success(monkeypatch):
    db = FakeDb()

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        assert "virgin" in contents
        return {
            "pages": [
                {
                    "page_id": "relationships",
                    "page_type": "relationships",
                    "visibility": "public",
                    "ai_body": (
                        "He has not had a significant past relationship and "
                        "is a virgin."
                    ),
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    written = _run(
        wiki_ingest.ingest_or_defer(
            db,
            "u1",
            "sess-voice-1",
            [
                Turn(
                    "ayma",
                    "Is there a past relationship that taught you the most "
                    "about what you're looking for now?",
                ),
                Turn("user", "No."),
                Turn("user", "I'm a virgin."),
                Turn(
                    "ayma",
                    "Got it, noted. Thanks for being open about that.",
                ),
            ],
        )
    )

    assert written == 1
    page = db.docs[("users", "u1", "wiki_pages", "relationships")]
    assert "virgin" in page["ai_body"]


def test_ingest_or_defer_runs_and_saves_data_despite_exhausted_credits(
    monkeypatch,
):
    """Founder directive (2026-09-20): "Instead of just marking them ingest
    pending I want even if the user run out of credits to save and invest
    [ingest] the data." A broke user's session must still get ingested —
    not deferred — so `ingest_or_defer` must not treat credit exhaustion as
    a reason to mark_pending any more."""
    import backfill_ops

    db = FakeDb()
    marked = []

    async def _fake_json_honoring_the_real_gate(
        contents, system_prompt, response_schema=None, enforce_cap=True, **kw
    ):
        if enforce_cap:
            raise token_ledger.TokenCapExceeded("out of credits")
        return {
            "pages": [
                {
                    "page_id": "relationships",
                    "page_type": "relationships",
                    "visibility": "public",
                    "ai_body": "He has not had a significant past relationship.",
                }
            ]
        }

    def _fake_mark_pending(_db, uid, session_id):
        marked.append((uid, session_id))

    monkeypatch.setattr(gemini, "generate_json", _fake_json_honoring_the_real_gate)
    monkeypatch.setattr(backfill_ops, "mark_pending", _fake_mark_pending)

    written = _run(
        wiki_ingest.ingest_or_defer(
            db, "u1", "sess-voice-2", [Turn("user", "I'm a virgin.")]
        )
    )

    assert written == 1  # ingested for real, not deferred
    page = db.docs[("users", "u1", "wiki_pages", "relationships")]
    assert "past relationship" in page["ai_body"]
    assert marked == []  # nothing marked pending — no genuine failure occurred


# --- source_log (§ fact-source-of-truth, 2026-09-21) ------------------------
#
# founder bug report: asked Ayma "where did you get this from" about his
# child's name/daycare (the Family section of Story/Ayma's-notes) and got a
# generic non-answer. `ai_body` is Gemini's own synthesised prose, so there's
# no per-sentence pointer — but keeping the verbatim conversation excerpt
# behind each real body change lets `find_fact_source` hand Ayma something
# real to quote instead of nothing.


def test_ingest_logs_the_verbatim_excerpt_when_a_new_page_is_created(monkeypatch):
    db = FakeDb()

    async def _fake_json(*a, **k):
        return {"pages": [{
            "page_id": "family", "page_type": "family", "visibility": "public",
            "ai_body": "His son Yahya goes to Sunshine Daycare.",
        }]}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    _run(wiki_ingest.ingest(
        db, "u1", "sess-fam",
        [
            Turn("user", "my son Yahya goes to Sunshine Daycare"),
            Turn("ayma", "got it, noted!"),
        ],
    ))

    page = db.docs[("users", "u1", "wiki_pages", "family")]
    log = page["source_log"]
    assert len(log) == 1
    assert log[0]["session_id"] == "sess-fam"
    assert "Yahya goes to Sunshine Daycare" in log[0]["excerpt"]
    assert "at" in log[0]


def test_ingest_appends_to_source_log_on_a_real_body_change_and_caps_it(
    monkeypatch,
):
    db = FakeDb()
    _seed_page(db, "u1", "family", {
        "ai_body": "old body", "page_type": "family",
        "source_log": [
            {"session_id": f"s{i}", "excerpt": f"old excerpt {i}", "at": "T"}
            for i in range(6)
        ],
    })

    async def _fake_json(*a, **k):
        return {"pages": [{
            "page_id": "family", "page_type": "family", "visibility": "public",
            "ai_body": "new body — his son's name came up",
        }]}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    _run(wiki_ingest.ingest(
        db, "u1", "sess-new", [Turn("user", "his name is actually Yahya")]
    ))

    log = db.docs[("users", "u1", "wiki_pages", "family")]["source_log"]
    # bounded to the last _MAX_SOURCE_LOG entries — oldest dropped
    assert len(log) == wiki_ingest._MAX_SOURCE_LOG
    assert log[-1]["session_id"] == "sess-new"
    assert "Yahya" in log[-1]["excerpt"]
    assert log[0]["session_id"] != "s0"  # the oldest entry was dropped


def test_ingest_with_record_source_false_never_logs_an_excerpt(monkeypatch):
    """`google_account.py` (Gmail/Calendar import) passes `record_source=
    False` — that module's own docstring promises the imported content is
    "never persisted verbatim to any Firestore doc" (more sensitive than a
    chat message, not even kept in raw_turns); `source_log` must honour
    that, not quietly reopen the hole."""
    db = FakeDb()

    async def _fake_json(*a, **k):
        return {"pages": [{
            "page_id": "family", "page_type": "family", "visibility": "private",
            "ai_body": "Has a young child; daycare mentioned in a recent email.",
        }]}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    _run(wiki_ingest.ingest(
        db, "u1", "",
        [Turn("user", "Email body from daycare.example.com: enrollment confirmed")],
        force_visibility="private", record_source=False,
    ))

    page = db.docs[("users", "u1", "wiki_pages", "family")]
    assert "source_log" not in page


def test_ingest_does_not_log_when_the_body_does_not_actually_change(
    monkeypatch,
):
    db = FakeDb()
    _seed_page(db, "u1", "family", {
        "ai_body": "His son Yahya goes to Sunshine Daycare.",
        "page_type": "family",
    })

    async def _fake_json(*a, **k):
        return {"pages": [{
            "page_id": "family", "page_type": "family", "visibility": "public",
            "ai_body": "His son Yahya goes to Sunshine Daycare.",  # unchanged
        }]}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    _run(wiki_ingest.ingest(
        db, "u1", "sess-noop", [Turn("user", "just chatting, nothing new")]
    ))

    page = db.docs[("users", "u1", "wiki_pages", "family")]
    assert "source_log" not in page


def test_ingest_or_defer_still_marks_pending_on_a_genuine_ingest_failure(
    monkeypatch,
):
    """A real failure unrelated to credits (a Gemini API error, a bad
    response, ...) must still flag the session for the nightly backfill
    sweep — the safety net `ingest_or_defer` keeps, just not for
    credit-exhaustion any more."""
    import backfill_ops

    db = FakeDb()
    marked = []

    async def _boom(*a, **k):
        raise RuntimeError("upstream 500")

    def _fake_mark_pending(_db, uid, session_id):
        marked.append((uid, session_id))

    monkeypatch.setattr(gemini, "generate_json", _boom)
    monkeypatch.setattr(backfill_ops, "mark_pending", _fake_mark_pending)

    written = _run(
        wiki_ingest.ingest_or_defer(
            db, "u1", "sess-voice-3", [Turn("user", "I'm a virgin.")]
        )
    )

    assert written == 0
    assert marked == [("u1", "sess-voice-3")]
