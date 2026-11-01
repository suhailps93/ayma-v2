"""Shared time/format helpers (sweep finding BE-#5).

Locks in the exact drifted semantics each call site kept when its private
copy was centralized into :mod:`timefmt` — especially the string/None/garbage
corners where the copies disagreed.
"""

from datetime import datetime, timezone

from timefmt import (
    iso_or_empty,
    iso_or_none,
    iso_or_str,
    parse_iso_utc,
    utcnow,
)

_DT = datetime(2026, 5, 1, 12, 30, 45, tzinfo=timezone.utc)


def test_utcnow_is_utc():
    now = utcnow()
    assert now.tzinfo == timezone.utc
    assert abs((now - datetime.now(timezone.utc)).total_seconds()) < 60


def test_iso_or_none_renders_datetimes_and_nones():
    assert iso_or_none(_DT) == "2026-05-01T12:30:45+00:00"
    assert iso_or_none(None) is None
    assert iso_or_none(1234) is None


def test_iso_or_none_maps_strings_to_none_by_default():
    # appearance/story's copy: a value with no isoformat (incl. str) -> None.
    assert iso_or_none("2026-05-01T12:30:45+00:00") is None


def test_iso_or_none_keeps_strings_for_report_hub():
    # report_hub's drifted copy passed strings through.
    assert (
        iso_or_none("2026-05-01", keep_strings=True) == "2026-05-01"
    )
    assert iso_or_none(None, keep_strings=True) is None
    assert iso_or_none(_DT, keep_strings=True) == _DT.isoformat()


def test_iso_or_str_falls_back_to_str():
    # google_account's copy (none=None).
    assert iso_or_str(_DT) == _DT.isoformat()
    assert iso_or_str(None) is None
    assert iso_or_str(1234) == "1234"


def test_iso_or_str_empty_none_for_fact_source():
    # fact_source's copy (none="").
    assert iso_or_str(None, none="") == ""
    assert iso_or_str(_DT, none="") == _DT.isoformat()
    assert iso_or_str(1234, none="") == "1234"


def test_iso_or_empty_has_no_str_fallback():
    # biometric_consent's copy: anything without isoformat -> "".
    assert iso_or_empty(_DT) == _DT.isoformat()
    assert iso_or_empty(None) == ""
    assert iso_or_empty("2026-05-01") == ""
    assert iso_or_empty(1234) == ""


def test_parse_iso_utc_parses_revenuecat_stamps():
    assert parse_iso_utc("2026-05-01T12:30:45Z") == _DT
    assert parse_iso_utc("2026-05-01T12:30:45+00:00") == _DT
    # Naive stamps are assumed UTC.
    assert parse_iso_utc("2026-05-01T12:30:45") == _DT
    assert parse_iso_utc("") is None
    assert parse_iso_utc(None) is None
    assert parse_iso_utc("not-a-date") is None
