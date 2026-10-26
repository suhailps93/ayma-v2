"""``send_dm_message`` (skills/dm_outreach.py): Ayma sending a DM to another
real person on the user's behalf with exactly one confirmation, enforced on
the server from the user's own latest line. See the module docstring.
"""

from __future__ import annotations

import asyncio

import pytest
from firebase_admin import firestore as fb_firestore

import skills
from skills import dm_outreach
from transcript import Turn


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# --- a minimal Firestore double, same shape as tests/test_dm_ops.py's -------

class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data or {})


class _DocRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    @property
    def id(self):
        return self.key[-1]

    def get(self):
        return _Snap(self.store.docs.get(self.key))

    def set(self, data, merge=False):
        cur = dict(self.store.docs.get(self.key) or {}) if merge else {}
        for k, v in data.items():
            if v is fb_firestore.DELETE_FIELD:
                cur.pop(k, None)
            else:
                cur[k] = v
        self.store.docs[self.key] = cur

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key
        self._auto = 0

    def document(self, doc_id=None):
        if doc_id is None:
            self._auto += 1
            doc_id = f"auto{self._auto}"
        return _DocRef(self.store, self.key + (doc_id,))


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def _messages(db: FakeDb, a: str, b: str) -> list[dict]:
    tid = "__".join(sorted((a, b)))
    return [
        v
        for k, v in db.docs.items()
        if len(k) == 4 and k[:2] == ("dm_threads", tid) and k[2] == "messages"
    ]


def _tools(db, uid="u1", session_id="s1", turns=None):
    return skills.make_session_tool_fns(
        db, uid,
        session_ctx={"session_id": session_id, "turn_index": 0, "turns": turns or []},
    )


async def _unflagged(_text):
    return {"flagged": False, "reason": "", "categories": []}


JORDAN = [{"uid": "other1", "name": "Jordan", "self": False}]
ASK = Turn("user", "send Jordan something")
TEXT = "hey! how was your trip?"


def _setup(monkeypatch, cards=JORDAN):
    monkeypatch.setattr(dm_outreach.explore, "explore", lambda *a, **k: cards)
    monkeypatch.setattr(dm_outreach.dm_moderation, "moderate", _unflagged)
    return FakeDb()


def _pid(out: str) -> str:
    return out.split('pending_id="', 1)[1].split('"', 1)[0] if "pending_id=" in out else ""


def _preview(db, person="Jordan", text=TEXT, turns=None):
    turns = turns if turns is not None else [ASK]
    out = _run(_tools(db, turns=turns)["send_dm_message"](person, text))
    return out, _pid(out)


def _confirm(db, reply, *, pid="", person="Jordan", text="", prior=None):
    if prior is None:
        prior = [ASK, Turn("ayma", f'To Jordan: "{TEXT}" Send it?')]
    turns = prior + [Turn("user", reply)]
    return _run(
        _tools(db, turns=turns)["send_dm_message"](
            person, text, confirmed=True, pending_id=pid
        )
    )


def _pending(db, sid="s1"):
    return (db.docs.get(("users", "u1", "sessions", sid)) or {}).get("pending_dm")


def _nav(db):
    return db.docs.get(("users", "u1", "app_commands", "pending"))


def test_one_send_tool_in_the_registry():
    names = {s.name for s in skills.all_skills()}
    assert "send_dm_message" in names
    assert "propose_dm_message" not in names


# --- preview: nothing reaches the recipient --------------------------------

def test_preview_records_pending_and_sends_nothing(monkeypatch):
    db = _setup(monkeypatch)
    out, pid = _preview(db)
    assert out.startswith("PREVIEW ONLY")
    assert "Jordan" in out and TEXT in out and pid
    assert not _messages(db, "u1", "other1")
    assert _nav(db) is None
    p = _pending(db)
    assert p["other_uid"] == "other1" and p["body"] == TEXT and p["id"] == pid


def test_preview_unknown_person_and_self(monkeypatch):
    db = _setup(monkeypatch, [{"uid": "u1", "name": "Me", "self": True}] + JORDAN)
    assert "couldn't find" in _preview(db, person="Nobody Here")[0]
    assert "couldn't find" in _preview(db, person="Me")[0]
    assert _pending(db) is None


# --- one yes sends at once -------------------------------------------------

@pytest.mark.parametrize("reply", [
    "Yeah, send it.", "yes", "Yes, send it.", "do it", "go ahead", "send",
    "Send it", "yep", "sure", "ok", "Yes please", "go for it",
])
def test_any_natural_yes_sends_exactly_the_previewed_text(monkeypatch, reply):
    db = _setup(monkeypatch)
    _, pid = _preview(db)
    out = _confirm(db, reply, pid=pid)
    assert out.startswith("SENT to Jordan")
    assert 'Reply with exactly: "Sent."' in out
    assert "thread_id=other1__u1" in out
    msgs = _messages(db, "u1", "other1")
    assert len(msgs) == 1
    assert msgs[0]["body"] == TEXT and msgs[0]["sender_uid"] == "u1"
    assert _pending(db) is None


@pytest.mark.parametrize("reply", [
    "no", "don't send it", "wait", "yes but change it", "not yet",
    "hmm", "what about Sam instead", "cancel",
])
def test_no_or_unclear_reply_never_sends(monkeypatch, reply):
    db = _setup(monkeypatch)
    _, pid = _preview(db)
    out = _confirm(db, reply, pid=pid)
    assert out.startswith("Not sent")
    assert not _messages(db, "u1", "other1")
    assert _pending(db) is not None
    assert _nav(db) is None


def test_confirm_on_the_line_that_asked_for_the_preview_is_refused(monkeypatch):
    """The model can't preview and confirm on the same user line."""
    db = _setup(monkeypatch)
    turns = [Turn("user", "yes, send Jordan something")]
    _, pid = _preview(db, turns=turns)
    out = _run(_tools(db, turns=turns)["send_dm_message"](
        "Jordan", "", confirmed=True, pending_id=pid))
    assert out.startswith("Not sent")
    assert not _messages(db, "u1", "other1")


def test_repeated_confirm_never_sends_or_navigates_twice(monkeypatch):
    db = _setup(monkeypatch)
    _, pid = _preview(db)
    assert _confirm(db, "yes", pid=pid).startswith("SENT")
    assert _nav(db)["path"] == "/dm/other1__u1"
    db.docs.pop(("users", "u1", "app_commands", "pending"))
    assert _confirm(db, "yes", pid=pid).startswith("Already sent")
    assert len(_messages(db, "u1", "other1")) == 1
    assert _nav(db) is None


# --- navigation to the thread after a successful send only -----------------

def test_successful_send_opens_the_dm_thread(monkeypatch):
    db = _setup(monkeypatch)
    _, pid = _preview(db)
    _confirm(db, "Yeah, send it.", pid=pid)
    nav = _nav(db)
    assert nav["action"] == "navigate"
    assert nav["screen"] == "dm"
    assert nav["path"] == "/dm/other1__u1"
    assert nav["id"]


def test_failed_send_does_not_navigate(monkeypatch):
    db = _setup(monkeypatch)
    db.docs[("blocks", "other1_u1")] = {}
    _, pid = _preview(db)
    out = _confirm(db, "yes", pid=pid)
    assert out.startswith("Not sent")
    assert not _messages(db, "u1", "other1")
    assert _nav(db) is None


def test_dm_path_comes_from_the_app_registry():
    assert dm_outreach._dm_path("a__b") == "/dm/a__b"


# --- edits, expiry, stale ids, wrong recipient -----------------------------

def test_edit_replaces_the_pending_send_and_asks_once_more(monkeypatch):
    db = _setup(monkeypatch)
    _, pid = _preview(db)
    out = _confirm(db, "make it shorter", pid=pid, text="how was the trip?")
    assert out.startswith("PREVIEW ONLY") and "how was the trip?" in out
    assert not _messages(db, "u1", "other1")
    new = _pending(db)
    assert new["id"] != pid and new["body"] == "how was the trip?"
    prior = [
        ASK,
        Turn("ayma", f'To Jordan: "{TEXT}" Send it?'),
        Turn("user", "make it shorter"),
        Turn("ayma", 'To Jordan: "how was the trip?" Send it?'),
    ]
    assert _confirm(db, "yes", pid=new["id"], prior=prior).startswith("SENT")
    assert [m["body"] for m in _messages(db, "u1", "other1")] == ["how was the trip?"]


def test_expired_preview_is_not_sendable(monkeypatch):
    db = _setup(monkeypatch)
    _, pid = _preview(db)
    db.docs[("users", "u1", "sessions", "s1")]["pending_dm"]["at"] -= (
        dm_outreach._PENDING_TTL_SECONDS + 1
    )
    out = _confirm(db, "yes", pid=pid, person="")
    assert out.startswith("Not sent")
    assert not _messages(db, "u1", "other1")
    assert _pending(db) is None


def test_stale_pending_id_re_asks_instead_of_sending(monkeypatch):
    db = _setup(monkeypatch)
    _preview(db)
    out = _confirm(db, "yes", pid="old-id")
    assert out.startswith("PREVIEW ONLY")
    assert not _messages(db, "u1", "other1")


def test_wrong_recipient_is_refused(monkeypatch):
    db = _setup(monkeypatch, JORDAN + [{"uid": "other2", "name": "Sam", "self": False}])
    _, pid = _preview(db)
    out = _confirm(db, "yes", pid=pid, person="Sam")
    assert out.startswith("Not sent") and "Jordan" in out
    assert not _messages(db, "u1", "other1")
    assert not _messages(db, "u1", "other2")


def test_pending_send_is_per_conversation(monkeypatch):
    db = _setup(monkeypatch)
    _, pid = _preview(db)
    turns = [ASK, Turn("ayma", "Send it?"), Turn("user", "yes")]
    out = _run(_tools(db, session_id="s2", turns=turns)["send_dm_message"](
        "", "", confirmed=True, pending_id=pid))
    assert out.startswith("Not sent")
    assert not _messages(db, "u1", "other1")


# --- the founder's 2026-10-26 transcript: text shown in a reply, then yes --

def test_text_shown_in_the_last_reply_then_yes_sends_without_a_second_ask(monkeypatch):
    db = _setup(monkeypatch, [{"uid": "other1", "name": "Dillu Shakeeb", "self": False}])
    body = (
        "Hey Dillu, I saw you're in San Jose too. What's been the best part "
        "of your week so far?"
    )
    turns = [
        Turn("user", "Yeah, why don't you send her something?"),
        Turn("ayma", "I'll draft something to get the ball rolling, how about: "
                     f'"{body}" Want me to send that?'),
        Turn("user", "Yeah, send it."),
    ]
    out = _run(_tools(db, turns=turns)["send_dm_message"]("Dillu", body, confirmed=True))
    assert out.startswith("SENT to Dillu Shakeeb")
    assert [m["body"] for m in _messages(db, "u1", "other1")] == [body]


def test_confirm_without_preview_and_unseen_text_only_previews(monkeypatch):
    db = _setup(monkeypatch)
    turns = [ASK, Turn("ayma", "Want me to send something?"), Turn("user", "yes")]
    out = _run(_tools(db, turns=turns)["send_dm_message"]("Jordan", TEXT, confirmed=True))
    assert out.startswith("PREVIEW ONLY")
    assert not _messages(db, "u1", "other1")


# --- moderation: flag, never block (dm_moderation.py policy) ---------------

def test_send_flags_but_always_delivers(monkeypatch):
    db = _setup(monkeypatch)

    async def _flagged(_text):
        return {"flagged": True, "reason": "harassment", "categories": ["harassment"]}

    monkeypatch.setattr(dm_outreach.dm_moderation, "moderate", _flagged)
    _, pid = _preview(db, text="nasty stuff")
    prior = [ASK, Turn("ayma", 'To Jordan: "nasty stuff" Send it?')]
    assert _confirm(db, "yes", pid=pid, prior=prior).startswith("SENT")
    msgs = _messages(db, "u1", "other1")
    assert msgs[0]["body"] == "nasty stuff" and msgs[0]["moderated"] is True


# --- voice: live window, the yes can land a moment after the tool call -----

def _voice_send(db, window):
    return dm_outreach.SEND_SKILL.bind(
        db, "u1", session_id="s1", turns=lambda: list(window)
    )


def test_voice_waits_for_the_late_transcript_of_the_yes(monkeypatch):
    db = _setup(monkeypatch)
    monkeypatch.setattr(dm_outreach, "_NEW_LINE_POLL_SECONDS", 0.01)
    window = [ASK]
    send = _voice_send(db, window)
    pid = _pid(_run(send("Jordan", TEXT)))
    window.append(Turn("ayma", f'To Jordan: "{TEXT}" Send it?'))

    async def _both():
        async def _late_yes():
            await asyncio.sleep(0.05)
            window.append(Turn("user", "Yeah, send it."))

        task = asyncio.ensure_future(_late_yes())
        result = await send("Jordan", "", confirmed=True, pending_id=pid)
        await task
        return result

    assert _run(_both()).startswith("SENT")
    assert len(_messages(db, "u1", "other1")) == 1


def test_voice_without_a_new_yes_stays_unsent(monkeypatch):
    db = _setup(monkeypatch)
    monkeypatch.setattr(dm_outreach, "_NEW_LINE_WAIT_SECONDS", 0.05)
    monkeypatch.setattr(dm_outreach, "_NEW_LINE_POLL_SECONDS", 0.01)
    window = [ASK]
    send = _voice_send(db, window)
    pid = _pid(_run(send("Jordan", TEXT)))
    assert _run(send("Jordan", "", confirmed=True, pending_id=pid)).startswith("Not sent")
    assert not _messages(db, "u1", "other1")


@pytest.mark.parametrize("line", ["Yeah, send it.", "Yes, send it.", "yes", "do it", "go ahead", "send"])
def test_short_confirmations_pass_the_misheard_fragment_guard(line):
    """voices.is_misheard_fragment refuses tool calls on short garbled
    non-English lines in a call; a short English yes must never be refused."""
    import voices

    assert not voices.is_misheard_fragment(line, "")
    assert not voices.is_misheard_fragment(line, "English")
    assert dm_outreach.is_confirmation(line)


def test_chip_labels_follow_the_outcome():
    from tool_labels import outcome_label

    sent = 'SENT to Jordan: "hi" (thread_id=a__b; the app is opening it)'
    assert outcome_label("send_dm_message", sent) == 'Sent to Jordan: "hi"'
    assert outcome_label("send_dm_message", "PREVIEW ONLY, x") == "Drafted a message"
    assert outcome_label("send_dm_message", "Not sent: no") == "Message not sent"
    assert outcome_label("deep_dive", "anything") is None
