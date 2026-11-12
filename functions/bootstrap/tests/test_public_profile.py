import time

import public_profile as pp
from pair_key import sorted_pair_key


class _Ts:
    """Stand-in for a Firestore timestamp — just needs `.timestamp()`."""

    def __init__(self, t):
        self._t = t

    def timestamp(self):
        return self._t


class _Snap:
    def __init__(self, doc_id, data, reference=None):
        self.id = doc_id
        self._data = data
        self.reference = reference

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def get(self):
        return _Snap(self.key[-1], self.store.docs.get(self.key), reference=self)

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key
        self._filter = None
        self._limit = None

    def document(self, doc_id):
        return _DocRef(self.store, self.key + (doc_id,))

    def where(self, field, _op, value):
        self._filter = (field, value)
        return self

    def limit(self, n):
        self._limit = n
        return self

    def stream(self):
        d = len(self.key)
        n = 0
        for k, v in list(self.store.docs.items()):
            if len(k) == d + 1 and k[:d] == self.key and v is not None:
                if self._filter and v.get(self._filter[0]) != self._filter[1]:
                    continue
                if self._limit is not None and n >= self._limit:
                    break
                n += 1
                yield _Snap(k[-1], v)


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def _setup(monkeypatch, db):
    monkeypatch.setattr(pp, "_photo_url", lambda sp: f"https://cdn/{sp}" if sp else None)
    monkeypatch.setattr(pp, "_score_for", lambda db, a, b: 0.82)


def test_build_returns_public_view_with_photos_pages_and_caller_state(monkeypatch):
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "her", "profile", "main")] = {
        "name": "Dana", "location": "Lisbon", "birthdate": "1994-01-01",
        "photos": [{"media_id": "m2", "order": 1}, {"media_id": "m1", "order": 0}],
    }
    db.docs[("users", "her", "user_media", "m1")] = {"storage_path": "uploads/her/a.jpg"}
    db.docs[("users", "her", "user_media", "m2")] = {"storage_path": "uploads/her/b.jpg"}
    # public: effective body (user_edits wins) with {{private}} spans stripped
    db.docs[("users", "her", "wiki_pages", "about")] = {
        "visibility": "public", "page_type": "about",
        "ai_body": "old narrative",
        "user_edits": "Grew up sailing. {{private}}Bad breakup.{{/private}}",
    }
    db.docs[("users", "her", "wiki_pages", "secret")] = {
        "visibility": "private", "page_type": "family", "ai_body": "hidden",
    }
    db.docs[("users", "her", "wiki_pages", "pulled")] = {
        "visibility": "public", "page_type": "work", "ai_body": "x",
        "user_hidden": True,
    }
    db.docs[("users", "me", "likes", "her")] = {"liked_at": 1}

    v = pp.build(db, "me", "her")
    assert v["name"] == "Dana" and v["location"] == "Lisbon"
    assert v["photos"] == ["https://cdn/uploads/her/a.jpg", "https://cdn/uploads/her/b.jpg"]
    assert [p["body"] for p in v["pages"]] == ["Grew up sailing."]  # span stripped
    assert v["liked"] is True
    assert v["score"] == 0.82
    assert v["self"] is False
    assert v["thread_id"]  # sorted-pair id present
    # No dm_threads doc at all for this pair -> never chatted, even though
    # thread_id (a bare deterministic pair key) is always present.
    assert v["has_chatted"] is False


# --- online / presence ----------------------------------------------------
# Real signal only (`last_active_at`, stamped on every authed request — same
# 5-minute window `/profiles/mini` already uses for its own `online` flag),
# never a hardcoded/placeholder value.

def test_build_reports_online_when_last_active_is_recent(monkeypatch):
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "her", "profile", "main")] = {"name": "Dana"}
    db.docs[("users", "her")] = {"last_active_at": _Ts(time.time() - 10)}
    v = pp.build(db, "me", "her")
    assert v["online"] is True


def test_build_reports_offline_when_last_active_is_stale(monkeypatch):
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "her", "profile", "main")] = {"name": "Dana"}
    db.docs[("users", "her")] = {"last_active_at": _Ts(time.time() - 600)}
    v = pp.build(db, "me", "her")
    assert v["online"] is False


def test_build_reports_offline_with_no_last_active_signal(monkeypatch):
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "her", "profile", "main")] = {"name": "Dana"}
    v = pp.build(db, "me", "her")
    assert v["online"] is False


def test_deep_dive_id_finds_the_subjects_own_self_dive(monkeypatch):
    """`deep_dive_id` must reflect the SUBJECT's own persisted report (their
    self-dive, corrections included) — checked under THEIR uid, not the
    caller's — so "Web search" shows "View" without re-running a search that
    would just throw away their corrections."""
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "her", "profile", "main")] = {"name": "Dana"}
    db.docs[("users", "her", "deep_dives", "name_dana")] = {
        "digest": {"summary": "hi", "confidence": "high", "facts": []},
        "name": "Dana", "target_uid": "",
    }

    v = pp.build(db, "me", "her")
    assert v["deep_dive_id"] == "uid_her"


def test_deep_dive_id_finds_an_earlier_cross_user_search(monkeypatch):
    """Falls back to a report someone else already ran on this subject when
    they have no self-dive of their own yet."""
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "her", "profile", "main")] = {"name": "Dana"}
    db.docs[("users", "her", "deep_dives", "uid_her")] = {
        "digest": {"summary": "hi", "confidence": "high", "facts": []},
        "name": "Dana", "target_uid": "her",
    }

    v = pp.build(db, "me", "her")
    assert v["deep_dive_id"] == "uid_her"


def test_deep_dive_id_empty_when_the_subject_has_no_report(monkeypatch):
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "her", "profile", "main")] = {"name": "Dana"}

    v = pp.build(db, "me", "her")
    assert v["deep_dive_id"] == ""


def test_build_returns_deleted_placeholder_without_touching_shared_thread(
    monkeypatch,
):
    """Point 3 of the founder's 2026-09-20 account-deletion request: B's
    existing match/thread/messages with a since-deleted A must survive, but
    A's profile should render as a clearly-labeled "deleted user" rather
    than their old data or a bare None."""
    db = FakeDb()
    _setup(monkeypatch, db)
    # `her` account was fully deleted: no live profile, but a live shared
    # thread + tombstone, exactly what account_ops.soft_delete leaves behind.
    db.docs[("deleted_users", "her")] = {"deleted_at": 1}
    db.docs[("dm_threads", sorted_pair_key("me", "her"))] = {
        "participants": sorted(["me", "her"]),
    }
    db.docs[
        ("dm_threads", sorted_pair_key("me", "her"), "messages", "m1")
    ] = {"sender": "her", "text": "hey there"}

    v = pp.build(db, "me", "her")
    assert v["deleted"] is True
    assert v["name"] == "Deleted user"
    assert v["photos"] == []
    assert v["pages"] == []
    assert v["blocked"] is False
    # the shared thread itself is untouched and still discoverable
    assert v["thread_id"] == sorted_pair_key("me", "her")
    assert v["has_chatted"] is True
    assert db.docs[("dm_threads", sorted_pair_key("me", "her"), "messages", "m1")][
        "text"
    ] == "hey there"


def test_build_is_none_for_a_nameless_or_missing_profile(monkeypatch):
    db = FakeDb()
    _setup(monkeypatch, db)
    assert pp.build(db, "me", "ghost") is None
    db.docs[("users", "blank", "profile", "main")] = {"location": "X", "name": "  "}
    assert pp.build(db, "me", "blank") is None


def test_build_marks_self(monkeypatch):
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "me", "profile", "main")] = {"name": "Me"}
    v = pp.build(db, "me", "me")
    assert v["self"] is True and v["score"] is None and v["thread_id"] is None
    assert v["has_chatted"] is False


# --- _has_chatted --------------------------------------------------------
# Regression coverage for the false "already chatted" bug: `thread_id` is a
# bare deterministic sorted-pair id (shared with `matches`) that exists for
# any two uids regardless of whether they've ever spoken. The Chat button's
# highlighted state must come from `has_chatted` instead.

def test_has_chatted_is_false_with_no_thread_doc_at_all():
    db = FakeDb()
    assert pp._has_chatted(db, "me", "her") is False


def test_has_chatted_is_false_for_a_thread_doc_with_zero_messages():
    # e.g. some future code path that creates the thread doc eagerly without
    # ever posting a message — must still read as "never chatted".
    db = FakeDb()
    tid = sorted_pair_key("me", "her")
    db.docs[("dm_threads", tid)] = {"participants": ["her", "me"]}
    assert pp._has_chatted(db, "me", "her") is False


def test_has_chatted_is_true_once_a_real_message_exists():
    db = FakeDb()
    tid = sorted_pair_key("me", "her")
    db.docs[("dm_threads", tid)] = {"participants": ["her", "me"]}
    db.docs[("dm_threads", tid, "messages", "m1")] = {
        "sender_uid": "her", "type": "text", "body": "hey",
    }
    assert pp._has_chatted(db, "me", "her") is True
    assert pp._has_chatted(db, "her", "me") is True  # order-independent


# --- _viewing_profile_context ------------------------------------------
# Shared by text chat's /chat (`viewing_profile_uid`) and voice's
# `current_screen` tool (`skills/app_control.py`) — one briefing, not two.

def test_viewing_profile_context_includes_name_age_location_and_wiki():
    db = FakeDb()
    db.docs[("users", "her", "profile", "main")] = {
        "name": "Dillu Renee", "location": "Austin", "birthdate": "1994-01-01",
    }
    db.docs[("users", "her", "wiki_pages", "about")] = {
        "visibility": "public", "page_type": "about", "title": "About",
        "ai_body": "Grew up sailing on the coast.",
    }
    out = pp._viewing_profile_context(db, "me", "her")
    assert "Dillu Renee" in out
    assert "Austin" in out
    assert "[About] Grew up sailing on the coast." in out


def test_viewing_profile_context_includes_the_private_match_read():
    db = FakeDb()
    db.docs[("users", "her", "profile", "main")] = {"name": "Dana"}
    db.docs[("matches", sorted_pair_key("me", "her"))] = {
        "ai_explanation": "They value stability; you crave novelty.",
    }
    out = pp._viewing_profile_context(db, "me", "her")
    assert "They value stability; you crave novelty." in out


def test_viewing_profile_context_is_empty_for_self_or_blank():
    db = FakeDb()
    assert pp._viewing_profile_context(db, "me", "") == ""
    assert pp._viewing_profile_context(db, "me", "me") == ""


def test_viewing_profile_context_falls_back_sensibly_for_an_unknown_uid():
    db = FakeDb()
    out = pp._viewing_profile_context(db, "me", "u-ghost")
    assert out  # doesn't crash, says something
    assert "profile" in out


# --- grounding: no ungrounded "match" claims ------------------------------
# Founder bug 2026-10-25: Ayma called a near-empty stranger "a great match on
# paper" with no computed score and no facts. The briefing must flag low/absent
# data (profile completeness, has_match_score=false, no notes) and tell the
# model, in so many words, not to assert compatibility.

def test_viewing_profile_context_flags_absent_data_and_forbids_match_claim():
    db = FakeDb()
    # 18%-complete profile, no public wiki, no match doc for the pair.
    db.docs[("users", "her", "profile", "main")] = {
        "name": "Dana",
        "completeness": {"score": 18},
    }
    out = pp._viewing_profile_context(db, "me", "her")
    assert "18% complete" in out
    assert "NO compatibility/match score has been computed" in out
    assert "no profile notes/wiki facts" in out
    # The explicit instruction that stops the hallucination.
    assert "do NOT have enough to judge compatibility" in out
    assert "run a match" in out


def test_viewing_profile_context_cites_a_real_computed_score():
    db = FakeDb()
    db.docs[("users", "her", "profile", "main")] = {
        "name": "Dana", "completeness": {"score": 80},
    }
    # The matches `score` field is stored 0–1 (report_adapters multiplies by
    # 100 for the UI); 0.734 is a 73% match.
    db.docs[("matches", sorted_pair_key("me", "her"))] = {
        "score": 0.734,
        "ai_explanation": "Shared love of the outdoors; different paces.",
    }
    out = pp._viewing_profile_context(db, "me", "her")
    assert "73/100 compatibility" in out
    assert "a compatibility score HAS been computed" in out
    # With a real score, the "not enough" guard must NOT fire.
    assert "do NOT have enough" not in out


def test_viewing_profile_context_scales_a_fractional_score_to_percent():
    # Founder bug 2026-10-29: a 99% match is stored as 0.99 on the 0–1 scale.
    # The briefing must read "99/100", never round it to "1/100" and let the
    # voice agent call a top match "low".
    db = FakeDb()
    db.docs[("users", "her", "profile", "main")] = {
        "name": "Sofia", "completeness": {"score": 90},
    }
    db.docs[("matches", sorted_pair_key("me", "her"))] = {"score": 0.99}
    out = pp._viewing_profile_context(db, "me", "her")
    assert "99/100 compatibility" in out
    assert "1/100" not in out
    assert "do NOT have enough" not in out


# --- image variants: server-minted variant URLs with per-entry fallback -----
# The client can't derive another user's variant URL (per-object Firebase
# tokens + owner-only storage.rules), so the backend mints thumb/medium URLs
# with fallback to the original.
import dataclasses  # noqa: E402


def _variants(monkeypatch, enabled: bool):
    monkeypatch.setattr(
        pp, "CONFIG", dataclasses.replace(pp.CONFIG, image_variants_enabled=enabled)
    )


def test_variant_url_returns_none_and_touches_no_blob_when_flag_off(monkeypatch):
    _variants(monkeypatch, False)
    called = []
    monkeypatch.setattr(pp, "_photo_url", lambda sp: called.append(sp) or "x")
    assert pp._variant_url("uploads/u/a.jpg", "thumb", 400) is None
    assert called == []  # early-return: no blob access, no GCS call


def test_variant_url_mints_variant_url_when_flag_on(monkeypatch):
    _variants(monkeypatch, True)
    monkeypatch.setattr(pp, "_photo_url", lambda sp: f"https://cdn/{sp}")
    assert (
        pp._variant_url("uploads/u/a.jpg", "thumb", 400)
        == "https://cdn/uploads/u/a__thumb_400.jpg"
    )


def test_photos_with_variants_uses_variant_when_present(monkeypatch):
    _variants(monkeypatch, True)
    # every path (original + variant) resolves -> thumb/medium are the variants
    monkeypatch.setattr(pp, "_photo_url", lambda sp: f"https://cdn/{sp}")
    db = FakeDb()
    db.docs[("users", "her", "user_media", "m1")] = {"storage_path": "uploads/her/a.jpg"}
    prof = {"photos": [{"media_id": "m1", "order": 0}]}
    originals, thumbs, mediums = pp._photos_with_variants(db, "her", prof)
    assert originals == ["https://cdn/uploads/her/a.jpg"]
    assert thumbs == ["https://cdn/uploads/her/a__thumb_400.jpg"]
    assert mediums == ["https://cdn/uploads/her/a__medium_1080.jpg"]


def test_photos_with_variants_falls_back_when_variant_missing(monkeypatch):
    _variants(monkeypatch, True)
    # originals resolve; variant objects don't exist -> _photo_url returns None
    def _url(sp):
        return None if ("__thumb_" in sp or "__medium_" in sp) else f"https://cdn/{sp}"

    monkeypatch.setattr(pp, "_photo_url", _url)
    db = FakeDb()
    db.docs[("users", "her", "user_media", "m1")] = {"storage_path": "uploads/her/a.jpg"}
    prof = {"photos": [{"media_id": "m1", "order": 0}]}
    originals, thumbs, mediums = pp._photos_with_variants(db, "her", prof)
    assert originals == ["https://cdn/uploads/her/a.jpg"]
    assert thumbs == originals  # fell back to the original
    assert mediums == originals


def test_build_populates_variant_fields_with_fallback(monkeypatch):
    _variants(monkeypatch, True)
    monkeypatch.setattr(pp, "_score_for", lambda db, a, b: 0.5)

    def _url(sp):
        # thumb exists, medium does not -> medium falls back to original
        if "__medium_" in sp:
            return None
        return f"https://cdn/{sp}"

    monkeypatch.setattr(pp, "_photo_url", _url)
    db = FakeDb()
    db.docs[("users", "her", "profile", "main")] = {
        "name": "Dana",
        "photos": [{"media_id": "m1", "order": 0}],
    }
    db.docs[("users", "her", "user_media", "m1")] = {"storage_path": "uploads/her/a.jpg"}
    v = pp.build(db, "me", "her")
    assert v["photos"] == ["https://cdn/uploads/her/a.jpg"]
    assert v["photos_thumb"] == ["https://cdn/uploads/her/a__thumb_400.jpg"]
    assert v["photos_medium"] == ["https://cdn/uploads/her/a.jpg"]  # fallback


# --- "AI-generated profile" label (payload flag) -------------------------
# The label must appear ONLY for AI-generated personas (sim / demo / seed) and
# NEVER for a real user. Absence of a reliable marker resolves to no label.


def test_build_labels_an_ai_generated_profile_from_the_explicit_marker(monkeypatch):
    """A seeded persona carrying the explicit `ai_generated` marker on its
    profile record is flagged on the payload, regardless of its uid."""
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "demo_seed_x", "profile", "main")] = {
        "name": "Nova",
        "ai_generated": True,
    }
    v = pp.build(db, "me", "demo_seed_x")
    assert v["ai_generated"] is True


def test_build_labels_a_practice_persona_by_uid_prefix(monkeypatch):
    """A practice-date persona (`demo_practice_*`) is flagged via the reserved
    uid prefix even if the explicit marker were somehow absent."""
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "demo_practice_maya", "profile", "main")] = {"name": "Maya"}
    v = pp.build(db, "me", "demo_practice_maya")
    assert v["ai_generated"] is True


def test_build_labels_a_demo_fixture_account_without_the_field(monkeypatch):
    """A known demo/judge fixture account (e.g. Sofia = ``demo-test2``) is
    labelled from its uid even when its profile doc is MISSING the explicit
    ``ai_generated`` field — the re-seed / missed-backfill case this fallback
    hardens against."""
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "demo-test2", "profile", "main")] = {"name": "Sofia"}
    v = pp.build(db, "me", "demo-test2")
    assert v["ai_generated"] is True


def test_build_labels_a_demo_edge_account_by_uid_prefix(monkeypatch):
    """A ``demo-edge-*`` corner-case fixture account is labelled from its uid
    prefix even with no explicit ``ai_generated`` field."""
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "demo-edge-001", "profile", "main")] = {"name": "Edge"}
    v = pp.build(db, "me", "demo-edge-001")
    assert v["ai_generated"] is True


def test_build_never_labels_a_real_user(monkeypatch):
    """A real user (ordinary uid, no marker — e.g. the founder or Dillu) is
    NEVER flagged. This is the critical guarantee: a real person mislabelled as
    AI-generated is the worst outcome."""
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "her", "profile", "main")] = {"name": "Dillu"}
    v = pp.build(db, "me", "her")
    assert v["ai_generated"] is False


def test_build_never_labels_a_normal_uid_without_the_field(monkeypatch):
    """An ordinary uid with no ``ai_generated`` field resolves to False — the
    fallback only ever adds labels for the reserved demo/practice uids, never a
    real account that happens to lack the field."""
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "u-regular-7", "profile", "main")] = {"name": "Alex"}
    v = pp.build(db, "me", "u-regular-7")
    assert v["ai_generated"] is False


def test_build_deleted_placeholder_is_not_labelled(monkeypatch):
    """A deleted-user tombstone is not an AI-generated persona."""
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("deleted_users", "her")] = {"at": 1}
    v = pp.build(db, "me", "her")
    assert v["ai_generated"] is False
