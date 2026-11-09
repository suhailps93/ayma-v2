"""image_gen.py — the founder-authorized image-generation restore
(2026-11-08): a pluggable provider catalog + a fail-closed daily cap, the
ONE scoped direct-Google inference exception.

The guarantees under test:

* the daily cap is the only door to a provider: call N+1 of a day is
  blocked BEFORE any provider call, and a counter-store failure means NO
  provider call (fail closed);
* the selected model is the one sent to its provider; with no user pick the
  default is the Gemini-direct entry; a saved pick routes to that provider;
* no silent fallback: a generation makes exactly one provider call, to the
  selected provider only; a non-ok state is a typed, honest outcome;
* the catalog is provider-agnostic: the Gemini-direct entry is the listed
  default, adding an entry is enough to list it, and an unconfigured
  provider (the shipped xai-direct state, no XAI_API_KEY) is not listed and
  a routed call returns ``unconfigured`` with no provider call.

Firestore and every provider call are faked — no network, no model spend.
"""

from __future__ import annotations

import asyncio
import dataclasses
from datetime import datetime
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest

import image_gen

PT = ZoneInfo("America/Los_Angeles")
NOW = datetime(2026, 11, 8, 10, 0, tzinfo=PT)


def _run(coro):
    return asyncio.run(coro)


# --- Firestore fake: the client-faithful transaction contract that
# web_search/practice learned the hard way (565075aa). A transaction handed
# out by db.transaction() is NOT in progress; any read/write through it raises
# until firestore.transactional begins it. ------------------------------------


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _Txn:
    def __init__(self, db):
        self._db = db
        self._writes = []
        self.in_progress = False
        self._id = None
        self._read_only = False
        self._max_attempts = 5

    def _clean_up(self):
        self._writes = []
        self.in_progress = False

    def _begin(self, retry_id=None):
        self._id = ("txn", id(self))
        self.in_progress = True

    def _commit(self):
        self.commit()

    def _rollback(self):
        self._writes = []
        self.in_progress = False

    def _require_in_progress(self):
        if not self.in_progress:
            raise ValueError(
                "Transaction not in progress, cannot be used in API requests."
            )

    def set(self, ref, data, merge=False):
        self._require_in_progress()
        self._writes.append((ref.key, dict(data)))

    def update(self, ref, data):
        self._require_in_progress()
        self._writes.append((ref.key, dict(data)))

    def commit(self):
        self._require_in_progress()
        self.in_progress = False
        if self._db.fail_commit is not None:
            raise self._db.fail_commit
        for key, data in self._writes:
            cur = dict(self._db.docs.get(key) or {})
            cur.update(data)
            self._db.docs[key] = cur
        self._writes = []


class _Ref:
    def __init__(self, db, key):
        self._db = db
        self.key = key

    def get(self, transaction=None):
        if transaction is not None and not transaction.in_progress:
            raise ValueError(
                "Transaction not in progress, cannot be used in API requests."
            )
        if self._db.fail_get is not None:
            raise self._db.fail_get
        return _Snap(self._db.docs.get(self.key))


class _Collection:
    def __init__(self, db, name):
        self._db = db
        self._name = name

    def document(self, doc_id):
        return _Ref(self._db, (self._name, doc_id))


class _Db:
    def __init__(self):
        self.docs = {}
        self.fail_get = None
        self.fail_commit = None

    def collection(self, name):
        return _Collection(self, name)

    def transaction(self):
        return _Txn(self)


def _config(monkeypatch, *, cap=100, xai_key="", xai_model="grok-imagine-image-2.0"):
    monkeypatch.setattr(
        image_gen,
        "CONFIG",
        SimpleNamespace(
            gemini_image_edit_model="gemini-2.5-flash-image",
            image_gen_xai_model=xai_model,
            image_gen_xai_api_key=xai_key,
            image_gen_daily_cap=cap,
            use_vertex=True,
            project_id="ayma-staging",
            gemini_location="global",
        ),
    )


def _pick(monkeypatch, provider):
    monkeypatch.setattr(image_gen, "read_image_model_pref", lambda uid: provider)


def _stub_caller(monkeypatch, provider, calls, *, result=(b"IMG", "image/png"), boom=None):
    async def _call(prompt, image, *, model_id, uid, feature):
        calls.append((provider, prompt, image, model_id, uid, feature))
        if boom is not None:
            raise boom
        return result

    monkeypatch.setitem(image_gen._PROVIDER_CALLERS, provider, _call)


# --- the hard cap -------------------------------------------------------------


def test_calls_up_to_cap_go_through_and_the_next_is_blocked_before_any_call(
    monkeypatch,
):
    _config(monkeypatch, cap=3)
    _pick(monkeypatch, "")  # no pick → default gemini-direct
    db = _Db()
    calls = []
    _stub_caller(monkeypatch, image_gen.PROVIDER_GEMINI_DIRECT, calls)
    outcomes = [
        _run(image_gen.generate(f"p{i}", uid="u", db=db, now=NOW))
        for i in range(4)
    ]
    assert all(o.status == image_gen.STATUS_OK for o in outcomes[:3])
    assert outcomes[3].status == image_gen.STATUS_PAUSED
    assert "used up for today" in outcomes[3].message
    assert len(calls) == 3  # the 4th generation never reached the provider
    assert db.docs[("image_gen_usage", "2026-11-08")]["count"] == 3


def test_cap_zero_pauses_and_never_calls_the_provider(monkeypatch):
    _config(monkeypatch, cap=0)
    _pick(monkeypatch, "")
    db = _Db()
    calls = []
    _stub_caller(monkeypatch, image_gen.PROVIDER_GEMINI_DIRECT, calls)
    out = _run(image_gen.generate("p", uid="u", db=db, now=NOW))
    assert out.status == image_gen.STATUS_PAUSED
    assert calls == []


def test_counter_store_failure_fails_closed_with_no_provider_call(monkeypatch):
    _config(monkeypatch, cap=100)
    _pick(monkeypatch, "")
    db = _Db()
    db.fail_get = RuntimeError("firestore unreachable")
    calls = []
    _stub_caller(monkeypatch, image_gen.PROVIDER_GEMINI_DIRECT, calls)
    out = _run(image_gen.generate("p", uid="u", db=db, now=NOW))
    assert out.status == image_gen.STATUS_ERROR
    assert "did not generate" in out.message
    assert calls == []  # fail closed — no provider call on an unverifiable cap


def test_succeeds_against_a_client_faithful_transaction(monkeypatch):
    """Regression guard: the reserve runs read-check-increment through
    firestore.transactional, so the first read does not raise "Transaction
    not in progress" (the trap that silently failed web search closed)."""
    _config(monkeypatch, cap=100)
    _pick(monkeypatch, "")
    db = _Db()
    calls = []
    _stub_caller(monkeypatch, image_gen.PROVIDER_GEMINI_DIRECT, calls)
    out = _run(image_gen.generate("p", uid="u", db=db, now=NOW))
    assert out.status == image_gen.STATUS_OK and len(calls) == 1


# --- selected-model plumbing + no fallback -----------------------------------


def test_no_pick_defaults_to_gemini_direct_and_sends_its_model_id(monkeypatch):
    _config(monkeypatch)
    _pick(monkeypatch, "")
    db = _Db()
    calls = []
    _stub_caller(monkeypatch, image_gen.PROVIDER_GEMINI_DIRECT, calls)
    out = _run(
        image_gen.generate("a cat", uid="u", feature="image_gen", db=db, now=NOW)
    )
    assert out.status == image_gen.STATUS_OK
    assert out.provider == image_gen.PROVIDER_GEMINI_DIRECT
    assert len(calls) == 1  # exactly one provider call, no fallback
    provider, prompt, image, model_id, uid, feature = calls[0]
    assert provider == image_gen.PROVIDER_GEMINI_DIRECT
    assert model_id == "gemini-2.5-flash-image"  # the picker value → provider
    assert (prompt, image, uid, feature) == ("a cat", None, "u", "image_gen")


def test_saved_pick_routes_to_that_provider_only(monkeypatch):
    _config(monkeypatch, xai_key="xai-secret")  # xai configured in this test
    _pick(monkeypatch, image_gen.PROVIDER_XAI_DIRECT)
    db = _Db()
    gem_calls, xai_calls = [], []
    _stub_caller(monkeypatch, image_gen.PROVIDER_GEMINI_DIRECT, gem_calls)
    _stub_caller(monkeypatch, image_gen.PROVIDER_XAI_DIRECT, xai_calls)
    out = _run(image_gen.generate("a cat", uid="u", db=db, now=NOW))
    assert out.status == image_gen.STATUS_OK
    assert len(xai_calls) == 1 and gem_calls == []  # no cross-provider fallback
    assert xai_calls[0][3] == "grok-imagine-image-2.0"


def test_provider_failure_is_a_typed_error_after_exactly_one_call(monkeypatch):
    _config(monkeypatch)
    _pick(monkeypatch, "")
    db = _Db()
    calls = []
    _stub_caller(
        monkeypatch, image_gen.PROVIDER_GEMINI_DIRECT, calls,
        boom=image_gen._ProviderError("safety refusal: no dice"),
    )
    out = _run(image_gen.generate("p", uid="u", db=db, now=NOW))
    assert out.status == image_gen.STATUS_ERROR
    assert out.message == "safety refusal: no dice"  # the honest refusal text
    assert len(calls) == 1  # one call, no retry onto another provider


def test_unknown_saved_pick_falls_through_to_the_default_not_an_error(monkeypatch):
    _config(monkeypatch)
    _pick(monkeypatch, "some-retired-provider")
    db = _Db()
    calls = []
    _stub_caller(monkeypatch, image_gen.PROVIDER_GEMINI_DIRECT, calls)
    out = _run(image_gen.generate("p", uid="u", db=db, now=NOW))
    assert out.status == image_gen.STATUS_OK
    assert out.provider == image_gen.PROVIDER_GEMINI_DIRECT


# --- the xai-direct unconfigured state (as shipped) --------------------------


def test_unconfigured_provider_returns_unconfigured_without_a_provider_call(
    monkeypatch,
):
    _config(monkeypatch, xai_key="")  # no XAI_API_KEY — the shipped state
    _pick(monkeypatch, image_gen.PROVIDER_XAI_DIRECT)
    db = _Db()
    calls = []
    _stub_caller(monkeypatch, image_gen.PROVIDER_XAI_DIRECT, calls)
    out = _run(image_gen.generate("p", uid="u", db=db, now=NOW))
    assert out.status == image_gen.STATUS_UNCONFIGURED
    assert out.provider == image_gen.PROVIDER_XAI_DIRECT
    assert calls == []  # never reaches the provider, never consumes the cap
    assert db.docs == {}  # the cap was not touched


# --- catalog / picker --------------------------------------------------------


def test_catalog_lists_gemini_default_and_hides_unconfigured_xai(monkeypatch):
    _config(monkeypatch, xai_key="")
    models = image_gen.available_models()
    ids = [m["id"] for m in models]
    assert ids == [image_gen.PROVIDER_GEMINI_DIRECT]  # xai hidden, no key
    assert models[0]["available"] is True
    assert models[0]["model"] == "gemini-2.5-flash-image"
    assert image_gen.default_model_id() == "gemini-2.5-flash-image"


def test_configuring_xai_lists_its_model_too(monkeypatch):
    _config(monkeypatch, xai_key="xai-secret")
    ids = [m["id"] for m in image_gen.available_models()]
    assert ids == [
        image_gen.PROVIDER_GEMINI_DIRECT, image_gen.PROVIDER_XAI_DIRECT
    ]


def test_adding_a_catalog_entry_is_enough_to_list_it(monkeypatch):
    """Provider-agnostic shape: a new entry pointing at its own config attrs
    is listed with no other change (listing derives purely from the catalog +
    config)."""
    _config(monkeypatch)
    # Give the fake CONFIG the new provider's model attr.
    image_gen.CONFIG.livekit_image_model = "livekit/some-image-model"
    new_entry = image_gen.ImageModel(
        provider="livekit-gateway",
        label="LiveKit image",
        description="A future LiveKit-served image model.",
        model_attr="livekit_image_model",
        key_attr=None,
    )
    monkeypatch.setattr(image_gen, "_CATALOG", image_gen._CATALOG + (new_entry,))
    ids = [m["id"] for m in image_gen.available_models()]
    assert "livekit-gateway" in ids


def test_default_provider_is_gemini_direct():
    assert image_gen.DEFAULT_PROVIDER == image_gen.PROVIDER_GEMINI_DIRECT


def test_paused_message_is_honest_about_the_reset_and_never_fakes_an_error():
    msg = image_gen.PAUSED_MESSAGE.lower()
    assert "used up for today" in msg and "midnight" in msg
    # It instructs the model NOT to dress the pause up as a glitch/error.
    assert "do not call it a glitch" in msg
