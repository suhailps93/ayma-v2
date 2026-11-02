from datetime import datetime, timedelta, timezone

import chat_history

_T0 = datetime(2026, 1, 1, tzinfo=timezone.utc)


class _Doc:
    def __init__(self, data):
        self._data = data
        self.id = str(data.get("_id", "session-x"))

    def to_dict(self):
        return {k: v for k, v in self._data.items() if k != "_id"}


class _Query:
    """Replays a fixed row list; Firestore has already ordered/limited it."""

    def __init__(self, rows):
        self._rows = rows

    def order_by(self, field, direction=None):
        name = getattr(direction, "name", direction)
        return _Query(sorted(
            self._rows,
            key=lambda r: r.get(field) or _T0 - timedelta(days=3650),
            reverse=name == "DESCENDING",
        ))

    def where(self, _field, _op, value):
        return _Query([r for r in self._rows
                       if (r.get("created_at") or _T0) < value])

    def limit(self, n):
        return _Query(self._rows[:n])

    def stream(self):
        return [_Doc(r) for r in self._rows]


class _ChatMessages:
    def __init__(self):
        self.rows = []

    def add(self, payload):
        payload = dict(payload)
        payload["created_at"] = _T0 + timedelta(minutes=len(self.rows))
        self.rows.append(payload)

    def order_by(self, *a, **k):
        return _Query(list(self.rows)).order_by(*a, **k)

    def where(self, field, op, value):
        assert op == "=="
        return _Query([r for r in self.rows if r.get(field) == value])


class _FakeDB:
    """collection("users").document(uid).collection("chat_messages" | "raw_turns")"""

    def __init__(self, *, chat_rows=None, raw_rows=None):
        self.cm = _ChatMessages()
        for r in (chat_rows or []):
            self.cm.rows.append(dict(r))
        self._raw = _Query(list(raw_rows or []))

    def collection(self, name):
        if name == "chat_messages":
            return self.cm
        if name == "raw_turns":
            return self._raw
        return self

    def document(self, _name):
        return self


def test_append_writes_role_text_and_image_path():
    db = _FakeDB()
    chat_history.append(
        db, "u1", "user", "  hi there  ", image_path="uploads/u1/x.jpg"
    )
    chat_history.append(db, "u1", "ayma", "hello")
    chat_history.append(db, "u1", "bogus", "dropped")
    chat_history.append(db, "u1", "user", "   ")
    assert [
        (r["role"], r["text"], r["image_path"]) for r in db.cm.rows
    ] == [
        ("user", "hi there", "uploads/u1/x.jpg"),
        ("ayma", "hello", ""),
    ]


def test_append_drops_a_shared_photo_placeholder_on_an_image_turn():
    db = _FakeDB()
    chat_history.append(
        db, "u1", "user", "(shared a photo)", image_path="uploads/u1/a.jpg"
    )
    chat_history.append(
        db, "u1", "user", "what's in this? [shared an image]",
        image_path="uploads/u1/b.jpg",
    )
    assert [(r["text"], r["image_path"]) for r in db.cm.rows] == [
        ("", "uploads/u1/a.jpg"),
        ("what's in this?", "uploads/u1/b.jpg"),
    ]


def test_recent_shows_the_image_not_the_placeholder_after_a_reload():
    # chat_messages has the real image row (no placeholder text); raw_turns
    # has the "(shared a photo)\n[shared a photo]" persisted version.
    db = _FakeDB(
        chat_rows=[
            {"role": "user", "text": "", "image_path": "uploads/u1/p.jpg",
             "created_at": _T0 + timedelta(minutes=1)},
        ],
        raw_rows=[
            {"turns": [{"role": "user",
                        "text": "(shared a photo)\n[shared a photo]"}],
             "updated_at": _T0 + timedelta(minutes=1)},
        ],
    )
    r = chat_history.recent(db, "u1", limit=40)
    assert [(m["text"], m["image_path"]) for m in r["messages"]] == [
        ("", "uploads/u1/p.jpg"),
    ]


def test_append_and_recent_carry_a_generated_image_url():
    """Founder bug 2026-09-27 (uid iWhWjiWhEpU7iyu9B9vy7GlT0PD2): a
    generate_image turn persisted only ``image_path`` under
    ``ayma_generated/…`` — a path Storage rules hide from the client SDK — so
    the image vanished from the transcript on reload. The persisted turn now
    carries the durable token ``image_url`` and ``recent`` returns it."""
    db = _FakeDB()
    chat_history.append(
        db, "u1", "ayma", "Here's a tree mapping your journey",
        image_path="ayma_generated/u1/gen.png",
        image_url="https://firebasestorage.googleapis.com/v0/b/x/o/gen?alt=media&token=t1",
        tools=["Generated an image"],
    )
    row = db.cm.rows[0]
    assert row["image_path"] == "ayma_generated/u1/gen.png"
    assert row["image_url"].endswith("token=t1")

    r = chat_history.recent(db, "u1", limit=40)
    (m,) = r["messages"]
    assert m["image_path"] == "ayma_generated/u1/gen.png"
    assert m["image_url"].endswith("token=t1")


def test_recent_derives_the_url_for_a_legacy_generated_image_row(monkeypatch):
    """Rows persisted before ``image_url`` existed (the founder's tree image)
    still render: a non-``uploads/`` path with no stored URL gets the durable
    URL derived server-side (the Admin SDK bypasses the Storage rules the
    client is stuck behind). An ``uploads/`` path never triggers it — the
    client resolves those itself."""
    derived: list[str] = []

    def _fake_derive(path):
        derived.append(path)
        return f"https://cdn/{path}?token=derived"

    monkeypatch.setattr(chat_history, "_generated_image_url", _fake_derive)
    db = _FakeDB(
        chat_rows=[
            {"role": "ayma", "text": "your tree",
             "image_path": "ayma_generated/u1/legacy.png",
             "created_at": _T0 + timedelta(minutes=1)},
            {"role": "user", "text": "look at this",
             "image_path": "uploads/u1/mine.jpg",
             "created_at": _T0 + timedelta(minutes=2)},
        ],
    )
    r = chat_history.recent(db, "u1", limit=40)
    by_role = {m["role"]: m for m in r["messages"]}
    assert by_role["ayma"]["image_url"] == (
        "https://cdn/ayma_generated/u1/legacy.png?token=derived"
    )
    assert by_role["user"]["image_url"] == ""
    assert derived == ["ayma_generated/u1/legacy.png"]


def test_generated_url_derivation_caches_successes_not_failures(monkeypatch):
    calls: list[str] = []
    answers = iter(["", "https://cdn/p.png?token=t"])

    def _fake_photo_url(path):
        calls.append(path)
        return next(answers)

    import public_profile

    monkeypatch.setattr(public_profile, "_photo_url", _fake_photo_url)
    chat_history._GENERATED_URL_CACHE.clear()
    # First call fails (transient) — not cached, so the next call retries and
    # its success IS cached; the third never reaches Storage.
    assert chat_history._generated_image_url("ayma_generated/u1/p.png") == ""
    assert chat_history._generated_image_url("ayma_generated/u1/p.png") == (
        "https://cdn/p.png?token=t"
    )
    assert chat_history._generated_image_url("ayma_generated/u1/p.png") == (
        "https://cdn/p.png?token=t"
    )
    assert calls == ["ayma_generated/u1/p.png"] * 2
    chat_history._GENERATED_URL_CACHE.clear()


def test_recent_returns_oldest_first_and_paginates():
    db = _FakeDB()
    for i in range(5):
        chat_history.append(db, "u1", "user", f"m{i}")

    page1 = chat_history.recent(db, "u1", limit=2)
    assert [m["text"] for m in page1["messages"]] == ["m3", "m4"]
    assert page1["next_before"] is not None

    page2 = chat_history.recent(
        db, "u1", before=datetime.fromisoformat(page1["next_before"]), limit=2
    )
    assert [m["text"] for m in page2["messages"]] == ["m1", "m2"]

    page3 = chat_history.recent(
        db, "u1", before=datetime.fromisoformat(page2["next_before"]), limit=2
    )
    assert [m["text"] for m in page3["messages"]] == ["m0"]
    assert page3["next_before"] is None


def test_recent_merges_raw_turns_voice_history_with_chat_messages():
    # chat_messages: one recent text turn (with an image). raw_turns: an older
    # voice session whose turns predate chat_messages -> both must show.
    db = _FakeDB(
        chat_rows=[
            {"role": "user", "text": "newest typed", "image_path": "uploads/u1/p.jpg",
             "created_at": _T0 + timedelta(hours=2)},
        ],
        raw_rows=[
            {"turns": [
                {"role": "user", "text": "hey"},
                {"role": "ayma", "text": "hi, what's up"},
                {"role": "user", "text": "just rambling out loud"},
             ], "updated_at": _T0 + timedelta(hours=1)},
        ],
    )
    r = chat_history.recent(db, "u1", limit=40)
    texts = [m["text"] for m in r["messages"]]
    assert texts == ["hey", "hi, what's up", "just rambling out loud", "newest typed"]
    # the image survives from chat_messages
    assert r["messages"][-1]["image_path"] == "uploads/u1/p.jpg"


def test_append_and_recent_carry_tool_labels_and_subject_image():
    db = _FakeDB()
    chat_history.append(
        db, "u1", "ayma", "Here's what I found.",
        tools=["Researched Jane Doe online", ""],
        subject_image="https://cdn/p.jpg",
    )
    chat_history.append(db, "u1", "user", "thanks")  # no tools
    r = chat_history.recent(db, "u1", limit=40)
    ayma = next(m for m in r["messages"] if m["role"] == "ayma")
    assert ayma["tools"] == ["Researched Jane Doe online"]
    assert ayma["subject_image"] == "https://cdn/p.jpg"
    user = next(m for m in r["messages"] if m["role"] == "user")
    assert user["tools"] == [] and user["subject_image"] == ""


def test_recent_excludes_dm_sourced_raw_turns():
    # DM ingest writes raw_turns/dm-{thread}-{msg}; those must not surface in
    # the Ayma chat transcript.
    db = _FakeDB(
        chat_rows=[
            {"role": "ayma", "text": "hey there", "image_path": "",
             "created_at": _T0 + timedelta(minutes=1)},
        ],
        raw_rows=[
            {"_id": "dm-aaa__bbb-msg1",
             "turns": [{"role": "user", "text": "hey boy what's upp"}],
             "updated_at": _T0 + timedelta(minutes=2)},
            {"_id": "01ABCSESSION",
             "turns": [{"role": "user", "text": "real ayma turn"}],
             "updated_at": _T0 + timedelta(minutes=3)},
        ],
    )
    texts = [m["text"] for m in chat_history.recent(db, "u1", limit=40)["messages"]]
    assert "hey boy what's upp" not in texts
    assert "real ayma turn" in texts
    assert "hey there" in texts


def test_recent_excludes_photo_context_raw_turns():
    # The photo pipeline writes raw_turns/photo-{mediaId} purely as wiki
    # substrate: an internal photo-context annotation, not an Ayma-chat turn.
    # It must NOT surface in the transcript as a (pink) user bubble (founder
    # bug R2-D3: the fragment "of themselves) Daniel shared this in chat,
    # striking a pose outside the cathedral with the pigeons." rendered as a
    # user message the user never wrote).
    db = _FakeDB(
        chat_rows=[
            {"role": "ayma", "text": "love that shot", "image_path": "",
             "created_at": _T0 + timedelta(minutes=1)},
        ],
        raw_rows=[
            {"_id": "photo-abc123",
             "turns": [{"role": "user",
                        "text": "(shared a photo of themselves) Daniel shared "
                                "this in chat, striking a pose outside the "
                                "cathedral with the pigeons."}],
             "updated_at": _T0 + timedelta(minutes=2)},
            {"_id": "01ABCSESSION",
             "turns": [{"role": "user", "text": "real ayma turn"}],
             "updated_at": _T0 + timedelta(minutes=3)},
        ],
    )
    texts = [m["text"] for m in chat_history.recent(db, "u1", limit=40)["messages"]]
    assert not any("striking a pose outside the cathedral" in t for t in texts)
    assert not any("of themselves)" in t for t in texts)
    assert "real ayma turn" in texts
    assert "love that shot" in texts


def test_recent_dedupes_a_turn_present_in_both_sources():
    db = _FakeDB(
        chat_rows=[
            {"role": "user", "text": "shared line", "image_path": "",
             "created_at": _T0 + timedelta(minutes=5)},
        ],
        raw_rows=[
            {"turns": [{"role": "user", "text": "shared line"},
                       {"role": "ayma", "text": "unique voice reply"}],
             "updated_at": _T0 + timedelta(minutes=6)},
        ],
    )
    r = chat_history.recent(db, "u1", limit=40)
    texts = [m["text"] for m in r["messages"]]
    assert texts.count("shared line") == 1
    assert "unique voice reply" in texts


def test_recent_dedupes_a_turn_repeated_inside_one_raw_turns_doc():
    # Real production shape (founder's account, iWhWjiWhEpU7iyu9B9vy7GlT0PD2,
    # 2026-09-26): a single session's persisted `turns` array held the same
    # exact (role, text) pair three times over — a Gemini Live session
    # restart mid-call replaying its whole running chat context, or two
    # independent writers racing the same doc. Every occurrence used to
    # surface as its own transcript row on reload, and — because that
    # reloaded, still-duplicated window is exactly what the client resends as
    # `recent_turns` on its next call — the duplication would re-enter
    # raw_turns and compound release over release instead of self-correcting.
    db = _FakeDB(
        raw_rows=[
            {"turns": [
                {"role": "user", "text": "can you clear my notifications"},
                {"role": "ayma", "text": "Sure, on it."},
                {"role": "user", "text": "why do you keep asking the same thing"},
                {"role": "user", "text": "can you clear my notifications"},
                {"role": "ayma", "text": "Sure, on it."},
                {"role": "user", "text": "can you clear my notifications"},
                {"role": "ayma", "text": "Sure, on it."},
                {"role": "user", "text": "one real new thing at the end"},
             ], "updated_at": _T0 + timedelta(hours=1)},
        ],
    )
    texts = [m["text"] for m in chat_history.recent(db, "u1", limit=40)["messages"]]
    assert texts == [
        "can you clear my notifications",
        "Sure, on it.",
        "why do you keep asking the same thing",
        "one real new thing at the end",
    ]


def test_recent_dedupes_a_turn_repeated_across_raw_turns_docs():
    # Same shape as above but split across two session docs (e.g. a voice
    # retry re-seeding a new session from an already-duplicated window) —
    # the newer doc (higher updated_at) wins and the older echo is dropped.
    db = _FakeDB(
        raw_rows=[
            {"turns": [{"role": "user", "text": "hello there"}],
             "updated_at": _T0 + timedelta(hours=1)},
            {"turns": [{"role": "user", "text": "hello there"},
                       {"role": "ayma", "text": "hi again"}],
             "updated_at": _T0 + timedelta(hours=2)},
        ],
    )
    texts = [m["text"] for m in chat_history.recent(db, "u1", limit=40)["messages"]]
    assert texts.count("hello there") == 1
    assert texts == ["hello there", "hi again"]


def test_recent_cursor_when_more_history_exists():
    db = _FakeDB(
        raw_rows=[
            {"turns": [{"role": "user", "text": f"t{i}"} for i in range(6)],
             "updated_at": _T0 + timedelta(hours=1)},
        ],
    )
    page = chat_history.recent(db, "u1", limit=4)
    assert [m["text"] for m in page["messages"]] == ["t2", "t3", "t4", "t5"]
    assert page["next_before"] is not None  # t0/t1 still older
    older = chat_history.recent(
        db, "u1", before=datetime.fromisoformat(page["next_before"]), limit=4
    )
    assert [m["text"] for m in older["messages"]] == ["t0", "t1"]


def test_append_stamps_the_client_msg_id_and_recent_returns_it():
    db = _FakeDB()
    chat_history.append(db, "u1", "user", "draw a cat", client_msg_id="cm-1")
    chat_history.append(db, "u1", "ayma", "done!", client_msg_id="cm-1")
    chat_history.append(db, "u1", "user", "older client, no id")
    assert [r.get("client_msg_id", "") for r in db.cm.rows] == [
        "cm-1", "cm-1", "",
    ]
    msgs = chat_history.recent(db, "u1", limit=40)["messages"]
    assert [(m["text"], m["client_msg_id"]) for m in msgs] == [
        ("draw a cat", "cm-1"),
        ("done!", "cm-1"),
        ("older client, no id", ""),
    ]


def test_reply_for_client_id_finds_the_finished_turn_only():
    db = _FakeDB()
    # In flight: only the user row would exist mid-turn — no reply yet.
    assert chat_history.reply_for_client_id(db, "u1", "cm-9") is None
    chat_history.append(
        db, "u1", "ayma", "your cat", client_msg_id="cm-9",
        tools=["Generated an image"], image_url="https://x/cat.png",
    )
    found = chat_history.reply_for_client_id(db, "u1", "cm-9")
    assert found == {
        "text": "your cat",
        "tools": ["Generated an image"],
        "image_url": "https://x/cat.png",
    }
    assert chat_history.reply_for_client_id(db, "u1", "cm-other") is None
    assert chat_history.reply_for_client_id(db, "u1", "") is None
