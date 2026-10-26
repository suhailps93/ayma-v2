import dataclasses
from datetime import datetime, timedelta, timezone

import pytest
import token_ledger
from config import CONFIG


class _Meta:
    def __init__(self, total=None, prompt=0, cand=0, cached=None):
        self.total_token_count = total
        self.prompt_token_count = prompt
        self.candidates_token_count = cand
        # google-genai's GenerateContentResponseUsageMetadata.
        # cached_content_token_count — None when the call had no implicit
        # cache hit (the SDK's pydantic default), an int subset of
        # prompt_token_count when it did.
        self.cached_content_token_count = cached


class _Resp:
    def __init__(self, meta):
        self.usage_metadata = meta


class _Inc:
    def __init__(self, n):
        self.n = n


class _AggVal:
    def __init__(self, n):
        self.value = n


class _EventSnap:
    def __init__(self, events, data):
        self._events = events
        self._data = data

    def to_dict(self):
        return dict(self._data)

    @property
    def reference(self):
        events, data = self._events, self._data

        class _Ref:
            @staticmethod
            def delete():
                try:
                    events.remove(data)
                except ValueError:
                    pass

        return _Ref()


class _EventsQuery:
    def __init__(self, events, field, direction=None, limit_n=None, min_ts=None):
        self._events = events
        self._field = field
        self._direction = direction
        self._limit = limit_n
        self._min_ts = min_ts

    def limit(self, n):
        return _EventsQuery(
            self._events, self._field, self._direction, n, self._min_ts
        )

    def where(self, field, op, value):
        assert op == ">="
        return _EventsQuery(
            self._events, field, self._direction, self._limit, value
        )

    def stream(self):
        rows = sorted(self._events, key=lambda d: d.get(self._field))
        if self._min_ts is not None:
            rows = [d for d in rows if d[self._field] >= self._min_ts]
        if self._direction == "DESCENDING":
            rows.reverse()
        if self._limit is not None:
            rows = rows[: self._limit]
        return iter(_EventSnap(self._events, d) for d in rows)


class _EventsCol:
    """The spend_events subcollection slice token_ledger uses: add(),
    count().get(), order_by(...).limit(...).stream()."""

    def __init__(self, store):
        self._events = store.setdefault("_events", [])

    def add(self, data):
        self._events.append(dict(data))

    def count(self):
        events = self._events

        class _Agg:
            @staticmethod
            def get():
                return [[_AggVal(len(events))]]

        return _Agg()

    def order_by(self, field, direction=None):
        return _EventsQuery(self._events, field, direction)


class _Doc:
    def __init__(self, store):
        self._s = store

    def get(self):
        s = self._s
        class _S:
            exists = any(k != "_events" for k in s)
            def to_dict(self_):
                return dict(s)
        return _S()

    def collection(self, _name):
        return _EventsCol(self._s)

    def set(self, payload, merge=False):
        s = self._s
        if "credits_added" in payload:
            v = payload["credits_added"]
            # Increment sentinel adds; a plain int is an absolute set (topup
            # now writes the computed absolute value).
            s["credits_added"] = (
                s.get("credits_added", 0) + v.n if isinstance(v, _Inc)
                else int(v)
            )
        if "billing" in payload:
            s.setdefault("billing", {}).update(payload["billing"])
        u = payload.get("token_usage")
        if u is None:
            return
        cur = s.setdefault(
            "token_usage",
            {"total": 0, "input": 0, "output": 0, "cost_usd": 0.0, "features": {}},
        )
        if isinstance(u.get("total"), _Inc):
            cur["total"] += u["total"].n
        if isinstance(u.get("input"), _Inc):
            cur["input"] = cur.get("input", 0) + u["input"].n
        if isinstance(u.get("output"), _Inc):
            cur["output"] = cur.get("output", 0) + u["output"].n
        # cached_input / cached_features start ABSENT (not in the setdefault
        # template) — exactly like production, where the fields only exist
        # once the first implicit-cache hit is recorded.
        if isinstance(u.get("cached_input"), _Inc):
            cur["cached_input"] = (
                cur.get("cached_input", 0) + u["cached_input"].n
            )
        for k, v in (u.get("cached_features") or {}).items():
            cf = cur.setdefault("cached_features", {})
            cf[k] = cf.get(k, 0) + (v.n if isinstance(v, _Inc) else v)
        if isinstance(u.get("cost_usd"), _Inc):
            cur["cost_usd"] = cur.get("cost_usd", 0.0) + u["cost_usd"].n
        # real_money_usd starts ABSENT (never in the setdefault template
        # above) — exactly like production, where the field only exists once
        # the first priced call after 2026-09-26 increments it.
        if isinstance(u.get("real_money_usd"), _Inc):
            cur["real_money_usd"] = (
                cur.get("real_money_usd", 0.0) + u["real_money_usd"].n
            )
        # Reset marker (reset_real_money): plain values, not Increments —
        # the baseline is an absolute snapshot and reset_at a SERVER_TIMESTAMP
        # sentinel (patched to "TS" here; production reads it back as a
        # datetime, so the fake stores one).
        if "real_money_reset_baseline" in u:
            cur["real_money_reset_baseline"] = float(
                u["real_money_reset_baseline"]
            )
        if "real_money_reset_at" in u:
            from datetime import datetime, timezone
            cur["real_money_reset_at"] = datetime.now(timezone.utc)
        for k, v in (u.get("features") or {}).items():
            cur["features"][k] = cur["features"].get(k, 0) + (
                v.n if isinstance(v, _Inc) else v)


class _Db:
    def __init__(self, store):
        self._store = store

    def collection(self, _):
        return self

    def document(self, _):
        return _Doc(self._store)


@pytest.fixture(autouse=True)
def _patch(monkeypatch):
    store = {}
    monkeypatch.setattr(token_ledger, "get_db", lambda: _Db(store))

    import firebase_admin.firestore as fs
    monkeypatch.setattr(fs, "Increment", _Inc)
    monkeypatch.setattr(fs, "SERVER_TIMESTAMP", "TS")
    return store


def test_record_adds_total_and_feature(_patch):
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1200)))
    token_ledger.record("u1", "chat", _Resp(_Meta(total=800)))
    token_ledger.record("u1", "matching", _Resp(_Meta(total=500)))
    u = token_ledger.usage("u1", include_dollars=True)
    assert u["total"] == 2500
    assert u["features"] == {"chat": 2000, "matching": 500}


def test_record_falls_back_to_prompt_plus_candidates(_patch):
    token_ledger.record("u1", "wiki", _Resp(_Meta(prompt=300, cand=100)))
    u = token_ledger.usage("u1", include_dollars=True)
    assert u["total"] == 400
    assert u["input"] == 300
    assert u["output"] == 100


def test_record_splits_input_and_output_tokens(_patch):
    """The Firestore doc gets input/output alongside total — the fields a
    real-dollar cost audit needs (PLAN.md F1/F2), additive to (never
    replacing) the existing total used for credit charging."""
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1200, prompt=800, cand=400)))
    token_ledger.record("u1", "chat", _Resp(_Meta(total=600, prompt=500, cand=100)))
    u = token_ledger.usage("u1", include_dollars=True)
    assert u["total"] == 1800
    assert u["input"] == 1300
    assert u["output"] == 500


def test_record_keeps_total_larger_than_input_plus_output_when_present(_patch):
    """When the SDK's own total_token_count exceeds prompt+candidates (e.g.
    thinking/tool-use tokens folded in), total is trusted as-is for credit
    charging while input/output stay the plain prompt/candidates split."""
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1000, prompt=300, cand=200)))
    u = token_ledger.usage("u1", include_dollars=True)
    assert u["total"] == 1000
    assert u["input"] == 300
    assert u["output"] == 200


def test_record_without_usage_metadata_records_nothing(_patch):
    token_ledger.record("u1", "chat", _Resp(None))
    u = token_ledger.usage("u1", include_dollars=True)
    assert u["total"] == 0
    assert u["input"] == 0
    assert u["output"] == 0


def test_record_is_noop_without_uid(_patch):
    token_ledger.record(None, "chat", _Resp(_Meta(total=999)))
    assert token_ledger.usage("u1", include_dollars=True)["total"] == 0


def test_check_and_record_never_raise_on_db_error(monkeypatch):
    def _boom():
        raise RuntimeError("firestore down")

    monkeypatch.setattr(token_ledger, "get_db", _boom)
    token_ledger.check("u1")  # swallowed
    token_ledger.record("u1", "chat", _Resp(_Meta(total=10)))  # swallowed


def test_usage_starts_cost_usd_at_zero_for_a_fresh_user(_patch):
    assert token_ledger.usage("u1", include_dollars=True)["cost_usd"] == 0


def test_record_accumulates_real_dollar_cost_from_input_output_split(_patch):
    """chat/wiki/matching/etc. all bill against gemini-3.7-flash: $0.75/1M
    input, $3.75/1M output (see token_ledger._MODEL_PRICING)."""
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=1_000_000, cand=1_000_000))
    )
    assert token_ledger.usage("u1", include_dollars=True)["cost_usd"] == pytest.approx(0.75 + 3.75)

    # Start from zero and add as calls come in — a second call adds more.
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=500_000, cand=0))
    )
    assert token_ledger.usage("u1", include_dollars=True)["cost_usd"] == pytest.approx(
        0.75 + 3.75 + 0.375
    )


def test_record_from_pre_split_usage_contributes_zero_cost(_patch):
    """A response with only total_token_count (no prompt/candidates split —
    how every usage doc looked before commit 278c562) must not be guessed
    into a dollar figure: cost_usd stays exactly 0."""
    token_ledger.record("u1", "chat", _Resp(_Meta(total=50_000)))
    u = token_ledger.usage("u1", include_dollars=True)
    assert u["total"] == 50_000
    assert u["cost_usd"] == 0


def test_cost_usd_for_voice_uses_audio_input_and_output_rates(_patch):
    # Gemini Live native-audio: $3.00/1M input (audio), $12.00/1M output.
    cost = token_ledger.cost_usd_for(
        token_ledger.FEATURE_VOICE, 1_000_000, 1_000_000
    )
    assert cost == pytest.approx(3.00 + 12.00)


def test_cost_usd_for_photo_edit_prices_image_output_tokens(_patch):
    """gemini-2.5-flash-image: input $0.30/M, text output $2.50/M, image
    output $30/M. A typical edit (~600 in, 1290 image-out tokens) = $0.0389."""
    cost = token_ledger.cost_usd_for(
        token_ledger.FEATURE_PHOTO_EDIT, 600, 1290, image_output_tokens=1290
    )
    assert cost == pytest.approx(600 * 0.30 / 1e6 + 1290 * 30 / 1e6)
    assert 3.8 < cost * 100 < 4.0  # credits
    mixed = token_ledger.cost_usd_for(
        token_ledger.FEATURE_PHOTO_EDIT, 0, 1_000_000, image_output_tokens=400_000
    )
    assert mixed == pytest.approx(0.4 * 30 + 0.6 * 2.5)


def test_image_output_share_reads_modality_details_else_all_output(_patch):
    from types import SimpleNamespace as NS

    model = CONFIG.gemini_image_edit_model
    detailed = NS(usage_metadata=NS(candidates_tokens_details=[
        NS(modality="MediaModality.TEXT", token_count=20),
        NS(modality="MediaModality.IMAGE", token_count=1290),
    ]))
    assert token_ledger.image_output_share(detailed, model, 1310) == 1290
    bare = NS(usage_metadata=NS(candidates_tokens_details=None))
    assert token_ledger.image_output_share(bare, model, 1310) == 1310
    assert token_ledger.image_output_share(detailed, CONFIG.gemini_model, 1310) == 0


def test_cost_usd_for_unpriced_model_is_zero_not_guessed(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(CONFIG, gemini_model="some-future-unpriced-model"),
    )
    assert token_ledger.cost_usd_for("chat", 1_000_000, 1_000_000) == 0.0


def test_cost_usd_for_zero_tokens_is_zero(_patch):
    assert token_ledger.cost_usd_for("chat", 0, 0) == 0.0


def test_add_logs_an_exact_per_call_record_on_success(monkeypatch, _patch):
    """token_ledger.add() must leave a greppable success-path log line (uid,
    feature, token counts) so historical spend can be reconstructed exactly
    — see agent.py's equivalent "voice-usage turn ..." line, which this
    mirrors field-for-field (uid=/in=/out=/total=)."""
    logged = []
    monkeypatch.setattr(
        token_ledger.logger, "info",
        lambda msg, *a, **k: logged.append(msg % a),
    )
    token_ledger.add(
        "u1", "chat", 300, input_tokens=200, output_tokens=100,
    )
    assert len(logged) == 1
    line = logged[0]
    assert line == (
        "token-usage add uid=u1 feature=chat provider=google_vertex model=gemini-3.7-flash "
        "in=200 out=100 cached=0 total=300"
    )


def test_record_logs_an_exact_per_call_record_on_success(monkeypatch, _patch):
    """record() delegates to add() — confirm the log line fires end-to-end
    through the real Gemini-response entry point too."""
    logged = []
    monkeypatch.setattr(
        token_ledger.logger, "info",
        lambda msg, *a, **k: logged.append(msg % a),
    )
    token_ledger.record(
        "u1", "wiki", _Resp(_Meta(total=400, prompt=300, cand=100))
    )
    assert logged == [
        "token-usage add uid=u1 feature=wiki provider=google_vertex model=gemini-3.7-flash "
        "in=300 out=100 cached=0 total=400"
    ]


def test_add_does_not_log_on_failure(monkeypatch):
    """The log line is success-path only — a failed write still goes through
    the existing logger.exception path, not the new info line."""
    def _boom():
        raise RuntimeError("firestore down")

    monkeypatch.setattr(token_ledger, "get_db", _boom)
    logged = []
    monkeypatch.setattr(
        token_ledger.logger, "info",
        lambda msg, *a, **k: logged.append(msg % a),
    )
    token_ledger.add("u1", "chat", 300)
    assert logged == []


def test_usage_has_no_fixed_shown_costs(_patch):
    """Credits are metered from real tokens only — no fixed estimates."""
    assert "costs" not in token_ledger.usage("u1", include_dollars=True)


# --- real-money ledger (founder request 2026-09-26) --------------------------


def test_add_writes_a_spend_event_with_cost_and_session(_patch):
    from datetime import datetime

    token_ledger.add(
        "u1", "chat", 2_000_000,
        input_tokens=1_000_000, output_tokens=1_000_000,
        session_id="s-abc",
    )
    events = _patch["_events"]
    assert len(events) == 1
    e = events[0]
    assert e["feature"] == "chat"
    assert e["model"] == "gemini-3.7-flash"
    assert e["session_id"] == "s-abc"
    assert (e["input"], e["output"], e["total"]) == (
        1_000_000, 1_000_000, 2_000_000
    )
    # $0.75/1M input + $3.75/1M output — the same cost_usd_for() figure the
    # user-doc increment gets, persisted per event.
    assert e["cost_usd"] == pytest.approx(0.75 + 3.75)
    assert isinstance(e["ts"], datetime)


def test_add_without_a_session_writes_an_event_with_no_session_id(_patch):
    """Background work whose trigger isn't a conversation records honestly:
    no fabricated session key — the endpoint's day-grouping picks it up."""
    token_ledger.add("u1", "completeness", 500, input_tokens=400,
                     output_tokens=100)
    e = _patch["_events"][0]
    assert "session_id" not in e
    assert e["feature"] == "completeness"


def test_real_money_usd_starts_absent_and_accumulates_from_zero(_patch):
    # Fresh user: the field has never been written -> reads as exactly 0.
    assert token_ledger.usage("u1", include_dollars=True)["real_money_usd"] == 0

    # Pre-tracking history: a user doc that already carries lifetime
    # cost_usd must NOT leak it into real_money_usd — tracking starts now.
    _patch["token_usage"] = {
        "total": 5_000_000, "input": 0, "output": 0,
        "cost_usd": 123.0, "features": {"chat": 5_000_000},
    }
    assert token_ledger.usage("u1", include_dollars=True)["real_money_usd"] == 0

    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=1_000_000, cand=1_000_000))
    )
    u = token_ledger.usage("u1", include_dollars=True)
    assert u["real_money_usd"] == pytest.approx(0.75 + 3.75)
    # cost_usd keeps its lifetime history + the new call; real_money doesn't.
    assert u["cost_usd"] == pytest.approx(123.0 + 0.75 + 3.75)


def test_spend_events_are_pruned_back_to_the_cap(monkeypatch, _patch):
    monkeypatch.setattr(token_ledger, "SPEND_EVENTS_CAP", 10)
    monkeypatch.setattr(token_ledger, "_SPEND_PRUNE_SLACK", 2)
    for i in range(13):
        token_ledger.add(
            "u1", "chat", 100, input_tokens=90, output_tokens=10,
            session_id=f"s-{i}",
        )
    events = _patch["_events"]
    # Prune fires once the cap is overshot by the slack (10 + 2 < 13) and
    # trims back to exactly the cap, oldest first.
    assert len(events) == 10
    assert events[0]["session_id"] == "s-3"
    assert events[-1]["session_id"] == "s-12"


def test_usage_groups_spend_by_conversation(monkeypatch, _patch):
    # A voice call: two Live turns in the same LiveKit session.
    for _ in range(2):
        token_ledger.add(
            "u1", "voice", 1_000_000,
            input_tokens=500_000, output_tokens=500_000,
            model="gemini-3.8-live", session_id="room-1",
        )
    # A chat conversation, with a wiki-ingest pass attached to the same
    # session (the caller knew which conversation triggered it).
    token_ledger.add(
        "u1", "chat", 1_000_000,
        input_tokens=1_000_000, output_tokens=0, session_id="s-77",
    )
    token_ledger.add(
        "u1", "wiki", 200_000,
        input_tokens=200_000, output_tokens=0, session_id="s-77",
    )
    # Background work with no conversation -> its own calendar-day line.
    token_ledger.add(
        "u1", "completeness", 100_000, input_tokens=100_000, output_tokens=0,
    )

    u = token_ledger.usage("u1", include_dollars=True)
    groups = {g["id"]: g for g in u["spend_groups"]}
    assert set(groups) == {"room-1", "s-77"} | {
        g for g in groups if g.startswith("day:")
    }

    voice = groups["room-1"]
    assert voice["kind"] == "voice"
    assert voice["events"] == 2
    # 2 × (0.5M × $3/M + 0.5M × $12/M) = 2 × $7.50
    assert voice["cost_usd"] == pytest.approx(15.0)
    assert voice["features"] == {"voice": pytest.approx(15.0)}
    assert voice["first_ts"] and voice["last_ts"]

    chat = groups["s-77"]
    assert chat["kind"] == "chat"
    assert chat["events"] == 2
    # chat 1M input × $0.75/M + wiki 0.2M × $0.75/M
    assert chat["cost_usd"] == pytest.approx(0.75 + 0.15)
    assert chat["features"] == {
        "chat": pytest.approx(0.75), "wiki": pytest.approx(0.15),
    }

    day = next(g for k, g in groups.items() if k.startswith("day:"))
    assert day["kind"] == "background"
    assert day["session_id"] == ""
    assert day["features"] == {"completeness": pytest.approx(0.075)}

    # Newest group first — the background add was the most recent event.
    assert u["spend_groups"][0]["id"].startswith("day:")
    # And the header total matches what the events accumulated.
    assert u["real_money_usd"] == pytest.approx(15.0 + 0.75 + 0.15 + 0.075)


def test_spend_groups_are_capped_and_newest_first(monkeypatch, _patch):
    monkeypatch.setattr(token_ledger, "SPEND_GROUPS_CAP", 2)
    for i in range(4):
        token_ledger.add(
            "u1", "chat", 100, input_tokens=100, output_tokens=0,
            session_id=f"s-{i}",
        )
    groups = token_ledger.spend_groups("u1")
    assert [g["id"] for g in groups] == ["s-3", "s-2"]


def test_spend_groups_is_empty_not_an_error_when_the_read_fails(monkeypatch):
    def _boom():
        raise RuntimeError("firestore down")

    monkeypatch.setattr(token_ledger, "get_db", _boom)
    assert token_ledger.spend_groups("u1") == []


# --- reset_real_money (founder request 2026-09-26, Reset button) --------------


def test_usage_never_reset_since_equals_all_time_with_null_reset_at(_patch):
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=1_000_000, cand=1_000_000))
    )
    u = token_ledger.usage("u1", include_dollars=True)
    assert u["real_money_all_time_usd"] == pytest.approx(0.75 + 3.75)
    assert u["real_money_since_reset_usd"] == u["real_money_all_time_usd"]
    assert u["real_money_usd"] == u["real_money_since_reset_usd"]
    assert u["real_money_reset_at"] is None


def test_reset_real_money_zeroes_since_reset_but_keeps_all_time(_patch):
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=1_000_000, cand=1_000_000))
    )
    res = token_ledger.reset_real_money("u1")

    # The returned state is the fresh usage view: tracker at zero, all-time
    # untouched, the reset stamped.
    assert res["real_money_since_reset_usd"] == 0
    assert res["real_money_all_time_usd"] == pytest.approx(0.75 + 3.75)
    assert res["real_money_reset_at"] is not None
    # Baseline snapshot persisted under token_usage on the user doc.
    assert _patch["token_usage"]["real_money_reset_baseline"] == pytest.approx(
        0.75 + 3.75
    )
    # Nothing deleted: the spend-event history (all-time's backing rows,
    # shown as pre-reset conversation rows) survives the reset.
    assert len(_patch["_events"]) == 1
    assert len(res["spend_groups"]) == 1


def test_since_reset_accumulates_from_zero_after_a_reset(_patch):
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=1_000_000, cand=1_000_000))
    )
    token_ledger.reset_real_money("u1")
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=500_000, cand=0))
    )
    u = token_ledger.usage("u1", include_dollars=True)
    assert u["real_money_since_reset_usd"] == pytest.approx(0.375)
    assert u["real_money_all_time_usd"] == pytest.approx(0.75 + 3.75 + 0.375)
    # The legacy key older installed clients render follows since-reset, so
    # the reset visibly works there too.
    assert u["real_money_usd"] == pytest.approx(0.375)


def test_reset_real_money_is_repeatable(_patch):
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=1_000_000, cand=1_000_000))
    )
    token_ledger.reset_real_money("u1")
    token_ledger.record("u1", "chat", _Resp(_Meta(prompt=500_000, cand=0)))
    res = token_ledger.reset_real_money("u1")
    assert res["real_money_since_reset_usd"] == 0
    assert res["real_money_all_time_usd"] == pytest.approx(0.75 + 3.75 + 0.375)


def test_reset_real_money_without_uid_is_a_noop(_patch):
    assert token_ledger.reset_real_money("") == {}
    assert "token_usage" not in _patch


# --- out_of_credits_message -------------------------------------------------


def test_out_of_credits_message_always_mentions_credits():
    for context in (
        token_ledger.CONTEXT_BODY_REPORT,
        token_ledger.CONTEXT_FACE_REPORT,
        token_ledger.CONTEXT_DEEP_DIVE,
        token_ledger.CONTEXT_PHOTO_EDIT,
        token_ledger.CONTEXT_CORRECTION,
        token_ledger.CONTEXT_CHAT,
    ):
        assert "credits" in token_ledger.out_of_credits_message(context)


def test_out_of_credits_message_is_specific_per_context():
    # Each context reads naturally for what the user was actually doing, not
    # a one-size-fits-all sentence — and every context gets a distinct
    # message (no two contexts collapse to the same text).
    body = token_ledger.out_of_credits_message(token_ledger.CONTEXT_BODY_REPORT)
    face = token_ledger.out_of_credits_message(token_ledger.CONTEXT_FACE_REPORT)
    deep_dive = token_ledger.out_of_credits_message(token_ledger.CONTEXT_DEEP_DIVE)
    photo_edit = token_ledger.out_of_credits_message(token_ledger.CONTEXT_PHOTO_EDIT)
    correction = token_ledger.out_of_credits_message(token_ledger.CONTEXT_CORRECTION)
    chat = token_ledger.out_of_credits_message(token_ledger.CONTEXT_CHAT)

    assert "body report" in body
    assert "face report" in face
    assert "web search" in deep_dive
    assert "photo" in photo_edit
    assert len({body, face, deep_dive, photo_edit, correction, chat}) == 6


def test_out_of_credits_message_default_context_is_chat():
    assert token_ledger.out_of_credits_message() == token_ledger.out_of_credits_message(
        token_ledger.CONTEXT_CHAT
    )


def test_out_of_credits_message_unknown_context_does_not_raise():
    # A typo'd/future context shouldn't 500 a request — it should still read
    # as a sentence.
    msg = token_ledger.out_of_credits_message("something_new")
    assert "credits" in msg
    assert msg.endswith(".")


# --- ledger model accuracy (cost program 2026-09-26, Phase 0) ----------------


def test_live_model_id_follows_the_dev_api_flag(monkeypatch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(CONFIG, gemini_live_use_dev_api=False),
    )
    assert token_ledger.live_model_id() == CONFIG.gemini_live_model

    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(CONFIG, gemini_live_use_dev_api=True),
    )
    assert token_ledger.live_model_id() == CONFIG.gemini_live_dev_model


def test_voice_feature_prices_against_the_actual_live_model(monkeypatch, _patch):
    """The pre-2026-09-26 accuracy bug: voice was always priced as the Vertex
    native-audio model while real traffic (GEMINI_LIVE_USE_DEV_API=true) ran
    gemini-3.1-flash-live-preview. _model_for_feature must follow the flag."""
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(CONFIG, gemini_live_use_dev_api=True),
    )
    assert (
        token_ledger._model_for_feature(token_ledger.FEATURE_VOICE)
        == CONFIG.gemini_live_dev_model
    )


def test_preview_live_model_has_a_pricing_entry():
    # The legacy preview stays priced: it's the GEMINI_LIVE_DEV_MODEL rollback
    # target and appears in historical ledger rows. No published preview
    # price — the 2.5 native-audio audio rates are mirrored so that traffic
    # never silently contributes $0.
    price = token_ledger._MODEL_PRICING["gemini-3.1-flash-live-preview"]
    assert price["input"] == 3.00
    assert price["output"] == 12.00


def test_3_8_live_model_has_a_pricing_entry():
    """`gemini-3.8-live` — the Dev-API voice model since the 2026-09-26
    upgrade — is priced at the published $3/M input, $12/M output audio
    rates, so voice traffic is billed under the model it actually runs."""
    price = token_ledger._MODEL_PRICING["gemini-3.8-live"]
    assert price["input"] == 3.00
    assert price["output"] == 12.00
    cost = token_ledger.cost_usd_for(
        token_ledger.FEATURE_VOICE, 1_000_000, 1_000_000,
        model="gemini-3.8-live",
    )
    assert cost == pytest.approx(3.00 + 12.00)


def test_cost_usd_for_prices_by_the_threaded_model_when_given(_patch):
    cost = token_ledger.cost_usd_for(
        token_ledger.FEATURE_VOICE, 1_000_000, 1_000_000,
        model="gemini-3.1-flash-live-preview",
    )
    assert cost == pytest.approx(3.00 + 12.00)
    # An explicitly threaded model overrides the per-feature fallback even
    # when it disagrees with it.
    text_cost = token_ledger.cost_usd_for(
        token_ledger.FEATURE_VOICE, 1_000_000, 1_000_000,
        model="gemini-3.7-flash",
    )
    assert text_cost == pytest.approx(0.75 + 3.75)


def test_record_threads_the_actual_model_into_cost(monkeypatch, _patch):
    seen = {}
    real = token_ledger.cost_usd_for

    def _spy(feature, i, o, *, cached_input_tokens=0, model=None, **kw):
        seen["model"] = model
        return real(
            feature, i, o, cached_input_tokens=cached_input_tokens, model=model
        )

    monkeypatch.setattr(token_ledger, "cost_usd_for", _spy)
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=100, cand=100)),
        model="gemini-3.7-flash",
    )
    assert seen["model"] == "gemini-3.7-flash"


# --- implicit-cache hit metering (byte-stable chat prefix, 2026-09-26) --------


def test_usage_from_response_extracts_cached_content_token_count():
    """cached_content_token_count is the exact attribute name on this SDK's
    (google-genai 2.20.0) GenerateContentResponseUsageMetadata."""
    i, o, t, c = token_ledger._usage_from_response(
        _Resp(_Meta(total=1200, prompt=800, cand=400, cached=600))
    )
    assert (i, o, t, c) == (800, 400, 1200, 600)


def test_usage_from_response_cached_is_zero_when_absent():
    # No cache hit: the SDK leaves the field None (pydantic default) — and a
    # response with no usage_metadata at all reports 0 everywhere.
    assert token_ledger._usage_from_response(
        _Resp(_Meta(total=400, prompt=300, cand=100))
    ) == (300, 100, 400, 0)
    assert token_ledger._usage_from_response(_Resp(None)) == (0, 0, 0, 0)


def test_record_accumulates_cached_input_total_and_per_feature(_patch):
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(total=1200, prompt=800, cand=400, cached=600))
    )
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(total=900, prompt=700, cand=200, cached=100))
    )
    token_ledger.record(
        "u1", "wiki", _Resp(_Meta(total=500, prompt=400, cand=100, cached=50))
    )
    u = token_ledger.usage("u1", include_dollars=True)
    # input still counts the FULL prompt (cached is a subset, not extra).
    assert u["input"] == 800 + 700 + 400
    assert u["cached_input"] == 600 + 100 + 50
    assert u["cached_features"] == {"chat": 700, "wiki": 50}


def test_record_without_cache_hits_changes_nothing(_patch):
    """cached=0 is the exact pre-cache-tracking behavior: no cached fields on
    the user doc, full-rate pricing, zeros in the usage view."""
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=1_000_000, cand=1_000_000))
    )
    assert "cached_input" not in _patch["token_usage"]
    assert "cached_features" not in _patch["token_usage"]
    u = token_ledger.usage("u1", include_dollars=True)
    assert u["cached_input"] == 0
    assert u["cached_features"] == {}
    assert u["cost_usd"] == pytest.approx(0.75 + 3.75)


def test_cost_usd_for_prices_cached_input_at_the_discounted_rate(_patch):
    """Implicit-cache hits bill at CACHED_INPUT_RATE_FACTOR (0.10) × the
    input rate — 90% off per the published Gemini pricing. The cached tokens
    are a subset of input: 0.6M fresh × $0.75/M + 0.4M cached × $0.075/M."""
    assert token_ledger.CACHED_INPUT_RATE_FACTOR == 0.10
    cost = token_ledger.cost_usd_for(
        "chat", 1_000_000, 0, cached_input_tokens=400_000,
    )
    assert cost == pytest.approx(600_000 / 1e6 * 0.75 + 400_000 / 1e6 * 0.075)
    # Output pricing is untouched by the cache discount.
    with_out = token_ledger.cost_usd_for(
        "chat", 1_000_000, 1_000_000, cached_input_tokens=400_000,
    )
    assert with_out == pytest.approx(cost + 3.75)


def test_cost_usd_for_fully_cached_input_costs_ten_percent(_patch):
    cost = token_ledger.cost_usd_for(
        "chat", 1_000_000, 0, cached_input_tokens=1_000_000,
    )
    assert cost == pytest.approx(0.075)


def test_cost_usd_for_clamps_cached_above_input(_patch):
    """A cached count larger than input can't buy a negative fresh charge —
    it clamps to fully-cached."""
    cost = token_ledger.cost_usd_for(
        "chat", 1_000_000, 0, cached_input_tokens=2_000_000,
    )
    assert cost == pytest.approx(0.075)


def test_record_with_a_cache_hit_discounts_real_money_end_to_end(_patch):
    token_ledger.record(
        "u1", "chat",
        _Resp(_Meta(prompt=1_000_000, cand=0, cached=1_000_000)),
    )
    u = token_ledger.usage("u1", include_dollars=True)
    assert u["cost_usd"] == pytest.approx(0.075)
    assert u["real_money_usd"] == pytest.approx(0.075)


def test_add_writes_cached_input_on_the_spend_event(_patch):
    token_ledger.add(
        "u1", "chat", 1_200, input_tokens=1_000, output_tokens=200,
        cached_input=800, session_id="s-abc",
    )
    e = _patch["_events"][0]
    assert e["cached_input"] == 800
    # And the event's cost carries the discount: 200 fresh + 800 cached.
    assert e["cost_usd"] == pytest.approx(
        200 / 1e6 * 0.75 + 800 / 1e6 * 0.075 + 200 / 1e6 * 3.75
    )


def test_add_without_cached_writes_a_zero_cached_input_event(_patch):
    token_ledger.add("u1", "chat", 300, input_tokens=200, output_tokens=100)
    assert _patch["_events"][0]["cached_input"] == 0


def test_add_logs_the_cached_count(monkeypatch, _patch):
    logged = []
    monkeypatch.setattr(
        token_ledger.logger, "info",
        lambda msg, *a, **k: logged.append(msg % a),
    )
    token_ledger.add(
        "u1", "chat", 300, input_tokens=200, output_tokens=100,
        cached_input=150,
    )
    assert logged == [
        "token-usage add uid=u1 feature=chat provider=google_vertex model=gemini-3.7-flash "
        "in=200 out=100 cached=150 total=300"
    ]


def test_spend_groups_sum_cached_input_per_group(_patch):
    from datetime import datetime, timezone

    token_ledger.add(
        "u1", "chat", 1_000, input_tokens=900, output_tokens=100,
        cached_input=500, session_id="s-1",
    )
    token_ledger.add(
        "u1", "chat", 1_000, input_tokens=900, output_tokens=100,
        cached_input=300, session_id="s-1",
    )
    token_ledger.add(
        "u1", "chat", 1_000, input_tokens=900, output_tokens=100,
        session_id="s-2",
    )
    # A pre-cache-tracking event (no cached_input field at all) in the same
    # conversation contributes 0, not an error.
    _patch["_events"].append({
        "ts": datetime.now(timezone.utc), "feature": "chat",
        "model": "gemini-3.7-flash", "input": 100, "output": 10,
        "total": 110, "cost_usd": 0.0, "session_id": "s-1",
    })

    groups = {g["id"]: g for g in token_ledger.spend_groups("u1")}
    assert groups["s-1"]["cached_input"] == 800
    assert groups["s-1"]["events"] == 3
    assert groups["s-2"]["cached_input"] == 0


# --- period_usage / friendly labels (Plan page "Where your credits went") ------


def _ev(_patch, feature, usd, ago=timedelta(0)):
    _patch.setdefault("_events", []).append({
        "ts": datetime.now(timezone.utc) - ago,
        "feature": feature,
        "cost_usd": usd,
    })


def test_every_feature_has_a_label():
    keys = {
        v for k, v in vars(token_ledger).items()
        if k.startswith("FEATURE_") and isinstance(v, str)
        and not k.startswith("FEATURE_LABEL")
    }
    assert keys
    missing = keys - set(token_ledger.FEATURE_LABELS)
    assert not missing, f"ledger features without a user-facing label: {missing}"
    for key, label in token_ledger.FEATURE_LABELS.items():
        assert label and label != key and "_" not in label


def test_period_usage_rows_sum_to_the_header_and_use_labels(_patch):
    _ev(_patch, "chat", 0.50)
    _ev(_patch, "deepdive", 0.25)
    _ev(_patch, "deepdive", 0.25)
    _ev(_patch, "completeness", 0.001)  # rounds to 0 credits -> no row
    out = token_ledger.period_usage("u1", "all")
    assert [(r["label"], r["credits"]) for r in out["features"]] == [
        ("Text chat with Ayma", 50), ("Web research", 50),
    ]
    assert out["total_credits"] == sum(r["credits"] for r in out["features"]) == 100
    assert out["since"] is None
    assert "cost_usd" not in str(out)


def test_period_usage_windows_filter_events(_patch):
    _ev(_patch, "chat", 0.10, ago=timedelta(days=1))
    _ev(_patch, "chat", 0.20, ago=timedelta(days=10))
    _ev(_patch, "chat", 0.40, ago=timedelta(days=60))
    assert token_ledger.period_usage("u1", "7d")["total_credits"] == 10
    assert token_ledger.period_usage("u1", "30d")["total_credits"] == 30
    assert token_ledger.period_usage("u1", "all")["total_credits"] == 70


def test_period_usage_since_credit_uses_the_latest_credit_stamp(_patch):
    _patch["token_usage"] = {"total": 0, "cost_usd": 0.0, "features": {}}
    token_ledger.credits("u1")  # initialise billing (stamps the start grant)
    stamp = _patch["billing"]["credits_updated_at"]
    _ev(_patch, "chat", 0.30, ago=timedelta(days=3))
    _ev(_patch, "voice", 0.05)
    out = token_ledger.period_usage("u1", "since_credit")
    assert out["since"] == stamp.isoformat()
    assert out["total_credits"] == 5
    assert [r["key"] for r in out["features"]] == ["voice"]


def test_last_credit_update_is_the_latest_of_billing_and_topup():
    early = datetime(2026, 10, 1, tzinfo=timezone.utc)
    late = datetime(2026, 10, 5, tzinfo=timezone.utc)
    assert token_ledger.last_credit_update(
        {"credits_updated_at": late}, {"credits_updated_at": early}
    ) == late
    assert token_ledger.last_credit_update({}, {"credits_updated_at": early}) == early
    assert token_ledger.last_credit_update({}, {}) is None


def test_period_usage_empty_period(_patch):
    out = token_ledger.period_usage("u1", "7d")
    assert out["features"] == [] and out["total_credits"] == 0


def test_period_usage_never_under_reports_past_the_retention_cap(monkeypatch, _patch):
    monkeypatch.setattr(token_ledger, "SPEND_EVENTS_CAP", 2)
    _ev(_patch, "chat", 0.10, ago=timedelta(days=5))
    _ev(_patch, "chat", 0.10, ago=timedelta(days=1))
    out = token_ledger.period_usage("u1", "all")
    oldest = min(e["ts"] for e in _patch["_events"])
    assert out["since"] == oldest.isoformat()


def test_period_usage_rejects_unknown_period(_patch):
    with pytest.raises(ValueError):
        token_ledger.period_usage("u1", "yesterday")


def test_usage_adds_period_usage_only_when_asked(_patch):
    assert "period_usage" not in token_ledger.usage("u1")
    assert token_ledger.usage("u1", period="all")["period_usage"]["period"] == "all"
