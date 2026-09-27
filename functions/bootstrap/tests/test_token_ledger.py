import dataclasses

import pytest
import token_ledger
from config import CONFIG


class _Meta:
    def __init__(self, total=None, prompt=0, cand=0):
        self.total_token_count = total
        self.prompt_token_count = prompt
        self.candidates_token_count = cand


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
    def __init__(self, events, field, direction=None, limit_n=None):
        self._events = events
        self._field = field
        self._direction = direction
        self._limit = limit_n

    def limit(self, n):
        return _EventsQuery(self._events, self._field, self._direction, n)

    def stream(self):
        rows = sorted(self._events, key=lambda d: d.get(self._field))
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
            exists = "token_usage" in s
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
    u = token_ledger.usage("u1")
    assert u["total"] == 2500
    assert u["features"] == {"chat": 2000, "matching": 500}


def test_record_falls_back_to_prompt_plus_candidates(_patch):
    token_ledger.record("u1", "wiki", _Resp(_Meta(prompt=300, cand=100)))
    u = token_ledger.usage("u1")
    assert u["total"] == 400
    assert u["input"] == 300
    assert u["output"] == 100


def test_record_splits_input_and_output_tokens(_patch):
    """The Firestore doc gets input/output alongside total — the fields a
    real-dollar cost audit needs (PLAN.md F1/F2), additive to (never
    replacing) the existing total used for credit charging."""
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1200, prompt=800, cand=400)))
    token_ledger.record("u1", "chat", _Resp(_Meta(total=600, prompt=500, cand=100)))
    u = token_ledger.usage("u1")
    assert u["total"] == 1800
    assert u["input"] == 1300
    assert u["output"] == 500


def test_record_keeps_total_larger_than_input_plus_output_when_present(_patch):
    """When the SDK's own total_token_count exceeds prompt+candidates (e.g.
    thinking/tool-use tokens folded in), total is trusted as-is for credit
    charging while input/output stay the plain prompt/candidates split."""
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1000, prompt=300, cand=200)))
    u = token_ledger.usage("u1")
    assert u["total"] == 1000
    assert u["input"] == 300
    assert u["output"] == 200


def test_record_without_usage_metadata_records_nothing(_patch):
    token_ledger.record("u1", "chat", _Resp(None))
    u = token_ledger.usage("u1")
    assert u["total"] == 0
    assert u["input"] == 0
    assert u["output"] == 0


def test_record_is_noop_without_uid(_patch):
    token_ledger.record(None, "chat", _Resp(_Meta(total=999)))
    assert token_ledger.usage("u1")["total"] == 0


def test_check_raises_when_out_of_credits(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=1
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1500)))  # used 2 > 1
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")


def test_check_passes_with_credits_left(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=5
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=999)))
    token_ledger.check("u1")  # no raise


def test_topup_adds_credits_and_clears_the_out_of_credits_gate(
    monkeypatch, _patch
):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=1
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1500)))  # used = 2
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")

    res = token_ledger.topup("u1", 100)

    # A reload gives *at least* `amount` usable credits, forgiving the overspend
    # (used 2 vs grant 1): new_added = max(0+100, 2-1+100) = 101 -> remaining 100.
    assert res["remaining"] == 100
    c = token_ledger.credits("u1")
    assert c["added"] == 101
    assert c["remaining"] == 100
    token_ledger.check("u1")  # no longer raises


def test_topup_from_a_deep_deficit_still_yields_exactly_amount(
    monkeypatch, _patch
):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=100
        ),
    )
    _patch["credits_added"] = 800
    token_ledger.record("u1", "voice", _Resp(_Meta(total=913_000)))  # used 913
    assert token_ledger.credits("u1")["remaining"] == 0  # 100 + 800 - 913

    token_ledger.topup("u1", 100)
    assert token_ledger.credits("u1")["remaining"] == 100  # one tap = 100 usable


def test_topup_for_a_user_in_the_black_just_adds_amount(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=100
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=42_000)))  # used 42
    assert token_ledger.credits("u1")["remaining"] == 58

    token_ledger.topup("u1", 100)
    assert token_ledger.credits("u1")["remaining"] == 158


def test_check_and_record_never_raise_on_db_error(monkeypatch):
    def _boom():
        raise RuntimeError("firestore down")

    monkeypatch.setattr(token_ledger, "get_db", _boom)
    token_ledger.check("u1")  # swallowed
    token_ledger.record("u1", "chat", _Resp(_Meta(total=10)))  # swallowed


def test_usage_reports_credits_on_the_free_grant(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=100
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=12000)))
    u = token_ledger.usage("u1")
    assert u["credits"] == {"grant": 100, "added": 0, "used": 12, "remaining": 88}
    assert u["tokens_per_credit"] == 1000


def test_credits_used_rounds_up_a_partial_credit(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(CONFIG, tokens_per_credit=1000),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1)))
    assert token_ledger.credits("u1") == {"grant": 100, "added": 0, "used": 1,
                                          "remaining": 99}


def test_credits_never_go_negative(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=5
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=99000)))
    assert token_ledger.credits("u1")["remaining"] == 0


def test_per_user_credit_grant_overrides_the_free_grant(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=100
        ),
    )
    _patch["credit_grant"] = 500
    token_ledger.record("u1", "chat", _Resp(_Meta(total=10000)))
    u = token_ledger.usage("u1")
    assert u["credits"] == {
        "grant": 500, "added": 0, "used": 10, "remaining": 490,
    }


def test_usage_starts_cost_usd_at_zero_for_a_fresh_user(_patch):
    assert token_ledger.usage("u1")["cost_usd"] == 0


def test_record_accumulates_real_dollar_cost_from_input_output_split(_patch):
    """chat/wiki/matching/etc. all bill against gemini-3.7-flash: $0.75/1M
    input, $3.75/1M output (see token_ledger._MODEL_PRICING)."""
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=1_000_000, cand=1_000_000))
    )
    assert token_ledger.usage("u1")["cost_usd"] == pytest.approx(0.75 + 3.75)

    # Start from zero and add as calls come in — a second call adds more.
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=500_000, cand=0))
    )
    assert token_ledger.usage("u1")["cost_usd"] == pytest.approx(
        0.75 + 3.75 + 0.375
    )


def test_record_from_pre_split_usage_contributes_zero_cost(_patch):
    """A response with only total_token_count (no prompt/candidates split —
    how every usage doc looked before commit 278c562) must not be guessed
    into a dollar figure: cost_usd stays exactly 0."""
    token_ledger.record("u1", "chat", _Resp(_Meta(total=50_000)))
    u = token_ledger.usage("u1")
    assert u["total"] == 50_000
    assert u["cost_usd"] == 0


def test_cost_usd_for_voice_uses_audio_input_and_output_rates(_patch):
    # Gemini Live native-audio: $3.00/1M input (audio), $12.00/1M output.
    cost = token_ledger.cost_usd_for(
        token_ledger.FEATURE_VOICE, 1_000_000, 1_000_000
    )
    assert cost == pytest.approx(3.00 + 12.00)


def test_cost_usd_for_photo_edit_prices_input_only(_patch):
    """gemini-2.5-flash-image bills output per generated image, not per
    output token — the ledger only counts tokens, so output cost is left
    unpriced (0) rather than guessed at a tokens-per-image ratio; input
    ($0.30/1M) is still priced."""
    cost = token_ledger.cost_usd_for(
        token_ledger.FEATURE_PHOTO_EDIT, 1_000_000, 1_000_000
    )
    assert cost == pytest.approx(0.30)


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
        "token-usage add uid=u1 feature=chat model=gemini-3.7-flash "
        "in=200 out=100 total=300"
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
        "token-usage add uid=u1 feature=wiki model=gemini-3.7-flash "
        "in=300 out=100 total=400"
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


def test_usage_lists_only_token_spending_actions_in_costs(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, credit_cost_match_score=12, credit_cost_photo_edit=5,
        ),
    )
    # Pass-1 pool matching is heuristic-only (no Gemini) -> not a credit cost.
    assert token_ledger.usage("u1")["costs"] == {
        "match_score": 12, "photo_edit": 5,
    }


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
    assert token_ledger.usage("u1")["real_money_usd"] == 0

    # Pre-tracking history: a user doc that already carries lifetime
    # cost_usd must NOT leak it into real_money_usd — tracking starts now.
    _patch["token_usage"] = {
        "total": 5_000_000, "input": 0, "output": 0,
        "cost_usd": 123.0, "features": {"chat": 5_000_000},
    }
    assert token_ledger.usage("u1")["real_money_usd"] == 0

    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=1_000_000, cand=1_000_000))
    )
    u = token_ledger.usage("u1")
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

    u = token_ledger.usage("u1")
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
    u = token_ledger.usage("u1")
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
    u = token_ledger.usage("u1")
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

    def _spy(feature, i, o, *, model=None):
        seen["model"] = model
        return real(feature, i, o, model=model)

    monkeypatch.setattr(token_ledger, "cost_usd_for", _spy)
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=100, cand=100)),
        model="gemini-3.7-flash",
    )
    assert seen["model"] == "gemini-3.7-flash"
