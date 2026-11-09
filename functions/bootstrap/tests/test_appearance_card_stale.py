"""Regression: a new Appearance run must produce a card showing THAT run's
analysed photos (founder bug 2026-11-08, bug_reports ix5dQmormP6Dw9ExUA53 /
feedback 8Kwtna5MU6uVzOHFuRJO + JBeNHOKiaGnaGCQ1zYuP).

Live staging evidence (uid iWhWjiWhEpU7iyu9B9vy7GlT0PD2, report created
2026-11-09T01:00:14Z): the current report's analysed pool is

    face: chat_1789025044885.jpg, photo_1793042094303_0.jpg
    body: photo_1788758548558.png
    attr: profile_1788113480993.heic, (dups), photo_1792823624642_0.jpg

but the profile's ``report_card_hidden_photos`` — written against an OLDER
report and never scoped to any run — already contained 4 of those 5 photos
(including the face hero). The sections below the card ignore the hidden
list and showed every current photo correctly, while the card showed only
the photos the stale list (plus the adapter's pool[0] un-hide workaround)
let through: a previously-removed old photo as hero, with most of the
current run's photos suppressed. The card therefore never updates on a
re-run.

Fix contract: the hidden list is a curation OF ONE REPORT VERSION. It is
stamped with the report's ``created_at`` when written
(:func:`appearance.set_card_hidden`) and only honoured while the current
report still carries that same ``created_at``
(:func:`appearance.read_card_hidden`). A legacy unstamped list, or one
stamped by an older run, is stale and must not hide anything from the
current card.
"""

import appearance
import report_adapters as ra

_PREFIX = "uploads/u1/photos/"
FACE = _PREFIX + "chat_1789025044885.jpg"
FACE2 = _PREFIX + "photo_1793042094303_0.jpg"
BODY = _PREFIX + "photo_1788758548558.png"
ATTR1 = _PREFIX + "profile_1788113480993.heic"
ATTR2 = _PREFIX + "photo_1792823624642_0.jpg"

T_OLD = "2026-11-02T10:00:00+00:00"
T_NOW = "2026-11-09T01:00:14.271000+00:00"

_DOC = {
    "id": "current",
    "created_at": T_NOW,
    "attributes": {
        "record": {
            "eye_color": {"value": "brown", "source": "stated", "confidence": "high"},
        },
        "source_photos": [ATTR1, FACE, FACE2, BODY, ATTR2],
    },
    "face": {"usable": True, "overall_score": 7.0, "source_photos": [FACE, FACE2]},
    "body": {"usable": True, "overall_score": 6.0, "source_photos": [BODY]},
    "photo_count": 5,
}

_POOL = [FACE, FACE2, BODY, ATTR1, ATTR2]


class _ProfileDoc:
    """A profile doc fake whose set() persists into the same dict get()
    reads back, so set -> read roundtrips behave like Firestore."""

    def __init__(self, doc=None):
        self.doc = dict(doc) if doc else None

    def get(self):
        doc = self.doc

        class _Snap:
            exists = doc is not None

            def to_dict(self):
                return dict(doc) if doc else None

        return _Snap()

    def set(self, data, merge=False):
        if merge and self.doc:
            self.doc.update(data)
        else:
            self.doc = dict(data)


def _patch(monkeypatch, profile_doc, created_at=T_NOW):
    doc = dict(_DOC)
    doc["created_at"] = created_at
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(doc))
    monkeypatch.setattr(
        appearance.schema, "profile_doc", lambda db, uid: profile_doc
    )
    return doc


def test_pool_matches_founder_shape():
    assert appearance._pool_from_data(_DOC) == _POOL


def test_legacy_unstamped_hidden_list_does_not_hide_current_run_photos(monkeypatch):
    """The founder's exact state: a hidden list written before any run
    scoping existed (no stamp), covering 4 of the 5 current pool photos
    including the hero. The current report's card must show ALL of the
    current run's photos — the adapter must surface no hidden ids."""
    profile = _ProfileDoc(
        {appearance.HIDDEN_PHOTOS_FIELD: [BODY, ATTR2, ATTR1, FACE]}
    )
    _patch(monkeypatch, profile)
    report, *_ = ra.appearance_blocks(object(), "u1")
    assert report["card_hidden_photos"] == []


def test_hidden_list_from_a_previous_run_is_ignored_after_a_rerun(monkeypatch):
    """A hidden list stamped by report version T_OLD must not hide photos
    from the current report (version T_NOW), even when every id is still
    in the pool and even when it covers the hero."""
    profile = _ProfileDoc(
        {
            appearance.HIDDEN_PHOTOS_FIELD: [FACE, BODY],
            appearance.HIDDEN_PHOTOS_REPORT_FIELD: T_OLD,
        }
    )
    _patch(monkeypatch, profile)
    report, *_ = ra.appearance_blocks(object(), "u1")
    assert report["card_hidden_photos"] == []


def test_set_hidden_stamps_the_current_report_version(monkeypatch):
    profile = _ProfileDoc({})
    _patch(monkeypatch, profile)
    out = appearance.set_card_hidden(object(), "u1", [ATTR1])
    assert out == [ATTR1]
    assert profile.doc[appearance.HIDDEN_PHOTOS_FIELD] == [ATTR1]
    assert profile.doc[appearance.HIDDEN_PHOTOS_REPORT_FIELD] == T_NOW


def test_hidden_curated_against_the_current_report_is_honoured(monkeypatch):
    """Remove-from-card still works within the report it was curated on:
    set, then re-read through the adapter — the hidden ids (including the
    hero, an explicit same-report removal) stay hidden."""
    profile = _ProfileDoc({})
    _patch(monkeypatch, profile)
    appearance.set_card_hidden(object(), "u1", [FACE, BODY])
    report, *_ = ra.appearance_blocks(object(), "u1")
    assert report["card_hidden_photos"] == [FACE, BODY]


def test_read_hidden_roundtrip_and_rerun_invalidation(monkeypatch):
    profile = _ProfileDoc({})
    _patch(monkeypatch, profile)
    appearance.set_card_hidden(object(), "u1", [ATTR2])
    assert appearance.read_card_hidden(object(), "u1") == [ATTR2]
    # A re-run persists a new report version: the same stored list is now
    # stale and reads back empty, so the new card shows the full new pool.
    _patch(monkeypatch, profile, created_at="2026-11-09T02:00:00+00:00")
    assert appearance.read_card_hidden(object(), "u1") == []
