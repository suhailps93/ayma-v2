"""OpenAI provider seam: routing, HTTP client error contract, the Responses-API
implementations, and the per-user dispatch inside ``gemini.py``
(docs/chatgpt-provider.md). OpenAI is faked with ``httpx.MockTransport``."""

import asyncio
import base64
import dataclasses
import json

import gemini
import httpx
import llm_provider
import openai_auth
import openai_client
import openai_provider
import pytest
import token_ledger
from config import CONFIG
from fake_firestore import FakeDb

PLAN = llm_provider.Route(uid="u1", billing=token_ledger.BILLING_PLAN)
API = llm_provider.Route(uid="u1", billing=token_ledger.BILLING_API)


def run(coro):
    return asyncio.run(coro)


class Api:
    """Scripted fake of https://api.openai.com/v1."""

    def __init__(self):
        self.requests: list[httpx.Request] = []
        self.script: list = []  # httpx.Response | callable(req) -> Response

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        nxt = self.script.pop(0) if len(self.script) > 1 else self.script[0]
        return nxt(request) if callable(nxt) else nxt

    def bodies(self):
        return [json.loads(r.content) for r in self.requests]


def ok(payload: dict) -> httpx.Response:
    return httpx.Response(200, json=payload)


def err(status: int, code: str = "") -> httpx.Response:
    return httpx.Response(status, json={"error": {"code": code}})


def msg(text: str, annotations=None) -> dict:
    return {
        "type": "message",
        "content": [
            {"type": "output_text", "text": text,
             "annotations": annotations or []}
        ],
    }


USAGE = {"input_tokens": 100, "output_tokens": 20,
         "input_tokens_details": {"cached_tokens": 10}}


@pytest.fixture
def api(monkeypatch):
    a = Api()
    monkeypatch.setattr(openai_client, "_transport", httpx.MockTransport(a.handler))
    monkeypatch.setattr(openai_client, "_RETRY_BACKOFF", 0)
    tokens = []

    async def fake_token(route, *, force_refresh=False):
        tokens.append(force_refresh)
        return "refreshed" if force_refresh else "tok"

    monkeypatch.setattr(llm_provider, "access_token", fake_token)
    a.token_calls = tokens
    return a


@pytest.fixture
def ledger(monkeypatch):
    calls = {"record": [], "check": []}
    monkeypatch.setattr(
        token_ledger, "record_openai",
        lambda uid, feature, usage, **kw: calls["record"].append(
            (uid, feature, usage, kw)
        ),
    )
    monkeypatch.setattr(
        token_ledger, "check",
        lambda uid, **kw: calls["check"].append((uid, kw)),
    )
    return calls


# ============================================================ HTTP client
def test_post_sends_the_bearer_to_the_configured_base_url(api):
    api.script = [ok({"id": "r"})]
    assert run(openai_client.responses(PLAN, {"model": "m"})) == {"id": "r"}
    (req,) = api.requests
    assert req.headers["authorization"] == "Bearer tok"
    assert str(req.url) == CONFIG.openai_base_url + "/responses"


def test_a_401_refreshes_once_and_retries(api):
    api.script = [err(401), ok({"id": "r"})]
    assert run(openai_client.responses(PLAN, {})) == {"id": "r"}
    assert api.token_calls == [False, True]
    assert api.requests[1].headers["authorization"] == "Bearer refreshed"


def test_a_persistent_401_drops_a_plan_connection_and_is_unavailable(
    api, monkeypatch
):
    dropped = []
    monkeypatch.setattr(llm_provider, "drop_connection", dropped.append)
    api.script = [err(401)]
    with pytest.raises(openai_client.ProviderUnavailable):
        run(openai_client.responses(PLAN, {}))
    assert dropped == [PLAN]


def test_a_persistent_401_keeps_an_api_key_route(api, monkeypatch):
    dropped = []
    monkeypatch.setattr(llm_provider, "drop_connection", dropped.append)
    api.script = [err(401)]
    with pytest.raises(openai_client.ProviderUnavailable):
        run(openai_client.responses(API, {}))
    assert dropped == []


@pytest.mark.parametrize("status", [403, 404])
def test_403_404_mean_not_available_to_this_credential(api, status):
    api.script = [err(status, "model_not_found")]
    with pytest.raises(openai_client.ProviderUnavailable):
        run(openai_client.responses(PLAN, {}))
    assert len(api.requests) == 1


@pytest.mark.parametrize(
    "resp",
    [err(402), err(429, "usage_limit_reached"), err(429, "insufficient_quota")],
)
def test_plan_limit_raises_the_cap_error_without_retrying(api, resp):
    api.script = [resp]
    with pytest.raises(token_ledger.ProviderLimitReached):
        run(openai_client.responses(PLAN, {}))
    assert len(api.requests) == 1


def test_transient_errors_are_retried_then_succeed(api):
    api.script = [err(429, "rate_limit_exceeded"), err(503), ok({"id": "r"})]
    assert run(openai_client.responses(PLAN, {})) == {"id": "r"}
    assert len(api.requests) == 3


def test_transient_errors_give_up_after_the_retries(api):
    api.script = [err(500)]
    with pytest.raises(openai_client.OpenAIError):
        run(openai_client.responses(PLAN, {}))
    assert len(api.requests) == 3


def test_transport_errors_are_retried(api):
    def boom(req):
        raise httpx.ConnectError("down")

    api.script = [boom]
    with pytest.raises(openai_client.OpenAIError):
        run(openai_client.responses(PLAN, {}))
    assert len(api.requests) == 3


def test_a_lost_connection_is_unavailable_not_a_crash(monkeypatch):
    async def gone(route, *, force_refresh=False):
        raise openai_auth.OpenAIAuthError("Reconnect ChatGPT")

    monkeypatch.setattr(llm_provider, "access_token", gone)
    with pytest.raises(openai_client.ProviderUnavailable):
        run(openai_client.responses(PLAN, {}))


# ================================================================== reply
async def _collect(agen):
    return [ev async for ev in agen]


def test_reply_returns_status_then_the_reply_and_meters_as_plan(api, ledger):
    api.script = [ok({"output": [msg("Hello [1] there")], "usage": USAGE})]
    events = run(_collect(openai_provider.generate_reply_events(
        PLAN, "hi", "be nice", uid="u1", feature="chat", session_id="s-1"
    )))
    assert events[0]["type"] == "status"
    assert events[-1]["type"] == "reply"
    assert events[-1]["text"] and "[1]" not in events[-1]["text"]
    (body,) = api.bodies()
    assert body["model"] == CONFIG.openai_model
    assert body["store"] is False
    assert body["instructions"] == "be nice"
    assert {"type": "web_search"} in body["tools"]
    ((uid, feature, usage, kw),) = ledger["record"]
    assert (uid, feature, usage) == ("u1", "chat", USAGE)
    assert kw["billing"] == "plan" and kw["model"] == CONFIG.openai_model
    assert kw["session_id"] == "s-1"
    assert ledger["check"] == [("u1", {"billing": "plan"})]


def test_reply_runs_a_function_tool_round_and_reports_it(api, ledger):
    api.script = [
        ok({"output": [{"type": "function_call", "id": "fc_1", "call_id": "c1",
                        "name": "lookup", "arguments": '{"q": "x"}'}],
            "usage": USAGE}),
        ok({"output": [msg("done")], "usage": USAGE}),
    ]
    seen = {}

    async def lookup(q):
        seen["q"] = q
        return {"found": q}

    events = run(_collect(openai_provider.generate_reply_events(
        PLAN, "hi", None,
        [{"name": "lookup", "description": "d",
          "parameters": {"type": "object", "properties": {"q": {"type": "string"}}}}],
        {"lookup": lookup}, uid="u1",
    )))
    assert seen == {"q": "x"}
    assert events[-1]["type"] == "reply" and events[-1]["text"] == "done"
    assert events[-1]["tools_used"]
    first, second = api.bodies()
    fn_tool = [t for t in first["tools"] if t["type"] == "function"][0]
    assert fn_tool["name"] == "lookup" and fn_tool["strict"] is False
    items = second["input"]
    call = [i for i in items if i.get("type") == "function_call"][0]
    assert call["call_id"] == "c1" and "id" not in call
    out = [i for i in items if i.get("type") == "function_call_output"][0]
    assert out["call_id"] == "c1" and json.loads(out["output"]) == {"found": "x"}
    assert len(ledger["record"]) == 2  # every round is metered


def test_a_failing_tool_is_reported_to_the_model_not_raised(api, ledger):
    api.script = [
        ok({"output": [{"type": "function_call", "call_id": "c1",
                        "name": "boom", "arguments": "{}"}], "usage": USAGE}),
        ok({"output": [msg("sorry")], "usage": USAGE}),
    ]

    def boom():
        raise ValueError("nope")

    run(_collect(openai_provider.generate_reply_events(
        PLAN, "hi", None, [{"name": "boom"}], {"boom": boom}, uid="u1",
    )))
    out = [i for i in api.bodies()[1]["input"]
           if i.get("type") == "function_call_output"][0]
    assert out["output"] == "error: nope"


def test_web_search_calls_are_priced_and_labelled(api, ledger):
    api.script = [ok({
        "output": [{"type": "web_search_call"}, {"type": "web_search_call"},
                   msg("found it")],
        "usage": USAGE,
    })]
    events = run(_collect(openai_provider.generate_reply_events(
        PLAN, "hi", None, uid="u1",
    )))
    assert events[-1]["tools_used"]
    kw = ledger["record"][0][3]
    assert kw["extra_cost_usd"] == pytest.approx(
        2 * token_ledger.OPENAI_WEB_SEARCH_USD_PER_CALL
    )


def test_an_empty_reply_raises(api, ledger):
    api.script = [ok({"output": [], "usage": USAGE})]
    with pytest.raises(RuntimeError, match="empty"):
        run(_collect(openai_provider.generate_reply_events(
            PLAN, "hi", None, uid="u1")))


def test_reply_image_is_sent_as_a_data_url(api, ledger):
    api.script = [ok({"output": [msg("nice photo")], "usage": USAGE})]
    run(_collect(openai_provider.generate_reply_events(
        PLAN, "look", None, image=(b"\x01\x02", "image/png"), uid="u1")))
    content = api.bodies()[0]["input"][0]["content"]
    assert content[0]["type"] == "input_image"
    assert content[0]["image_url"].startswith("data:image/png;base64,")


def test_the_credit_gate_applies_to_api_billing_only(api, ledger):
    api.script = [ok({"output": [msg("x")], "usage": USAGE})]
    run(_collect(openai_provider.generate_reply_events(API, "hi", None, uid="u1")))
    assert ledger["check"] == [("u1", {"billing": "api"})]


# =============================================================== research
def test_research_returns_prose_and_deduped_citations(api, ledger):
    api.script = [ok({
        "output": [{"type": "web_search_call"}, msg("Answer", [
            {"type": "url_citation", "url": "https://a.test", "title": "A"},
            {"type": "url_citation", "url": "https://a.test", "title": "A"},
            {"type": "url_citation", "url": "https://b.test", "title": ""},
        ])],
        "usage": USAGE,
    })]
    text, sources = run(openai_provider.research(PLAN, "q", "sys", uid="u1",
                                                 feature="research"))
    assert text == "Answer"
    assert sources == [{"url": "https://a.test", "title": "A"},
                       {"url": "https://b.test", "title": "https://b.test"}]
    assert api.bodies()[0]["tools"] == [{"type": "web_search"}]
    assert ledger["record"][0][3]["extra_cost_usd"] > 0


# ================================================================== json
def test_generate_json_parses_and_puts_the_schema_in_the_instructions(api, ledger):
    api.script = [ok({"output": [msg('```json\n{"a": 1}\n```')], "usage": USAGE})]
    schema = {"type": "object", "properties": {"a": {"type": "integer"}}}
    out = run(openai_provider.generate_json(
        PLAN, "data", "sys", schema, uid="u1", feature="wiki"))
    assert out == {"a": 1}
    (body,) = api.bodies()
    assert body["text"] == {"format": {"type": "json_object"}}
    assert '"properties"' in body["instructions"]
    assert "JSON" in body["input"][0]["content"][-1]["text"]


def test_generate_json_enforce_cap_false_skips_the_gate(api, ledger):
    api.script = [ok({"output": [msg("{}")], "usage": USAGE})]
    run(openai_provider.generate_json(
        PLAN, "d", "s", uid="u1", enforce_cap=False))
    assert ledger["check"] == []


def test_generate_json_takes_single_and_multiple_images(api, ledger):
    api.script = [ok({"output": [msg("{}")], "usage": USAGE})]
    run(openai_provider.generate_json(
        PLAN, "d", "s", image=(b"1", "image/jpeg"), uid="u1"))
    run(openai_provider.generate_json(
        PLAN, "d", "s", images=[(b"1", "image/jpeg"), (b"2", "image/png")],
        uid="u1"))
    one, two = api.bodies()
    assert sum(c["type"] == "input_image" for c in one["input"][0]["content"]) == 1
    assert sum(c["type"] == "input_image" for c in two["input"][0]["content"]) == 2


def test_generate_json_empty_or_bad_output_raises(api, ledger):
    api.script = [ok({"output": [], "usage": USAGE})]
    with pytest.raises(RuntimeError):
        run(openai_provider.generate_json(PLAN, "d", "s", uid="u1"))
    api.script = [ok({"output": [msg("not json")], "usage": USAGE})]
    with pytest.raises(ValueError):
        run(openai_provider.generate_json(PLAN, "d", "s", uid="u1"))


# ================================================================== image
def test_generate_image_decodes_the_result_and_prices_the_image_model(api, ledger):
    png = b"\x89PNG-bytes"
    api.script = [ok({
        "output": [{"type": "image_generation_call", "output_format": "png",
                    "result": base64.b64encode(png).decode()}],
        "usage": USAGE,
        "tool_usage": {"image_gen": {"input_tokens": 50, "output_tokens": 1000}},
    })]
    data, mime = run(openai_provider.generate_image(
        PLAN, "a cat", image=(b"ref", "image/png"), uid="u1", feature="misc"))
    assert data == png and mime == "image/png"
    (body,) = api.bodies()
    tool = body["tools"][0]
    assert tool["type"] == "image_generation"
    assert tool["model"] == CONFIG.openai_image_model
    assert body["tool_choice"] == {"type": "image_generation"}
    models = [c[3]["model"] for c in ledger["record"]]
    assert models == [CONFIG.openai_model, CONFIG.openai_image_model]


def test_generate_image_without_an_image_raises_with_the_refusal(api, ledger):
    api.script = [ok({"output": [msg("I can't make that")], "usage": USAGE})]
    with pytest.raises(RuntimeError, match="can't make that"):
        run(openai_provider.generate_image(PLAN, "x", uid="u1"))


def test_no_model_id_is_hardcoded_outside_config(api, ledger):
    """Every model id on the wire comes from config (AGENTS.md)."""
    api.script = [ok({"output": [msg("{}")], "usage": USAGE})]
    run(openai_provider.generate_json(PLAN, "d", "s", uid="u1"))
    assert api.bodies()[0]["model"] == CONFIG.openai_model
    import pathlib
    import re

    root = pathlib.Path(openai_provider.__file__).parent
    for name in ("openai_provider.py", "openai_client.py", "llm_provider.py",
                 "openai_auth.py"):
        assert not re.search(r"\bgpt-\d", (root / name).read_text()), name


# ============================================================== routing
@pytest.fixture
def routing(monkeypatch):
    def _cfg(**over):
        cfg = dataclasses.replace(llm_provider.CONFIG, **over)
        monkeypatch.setattr(llm_provider, "CONFIG", cfg)

    llm_provider.invalidate()
    _cfg(chatgpt_signin_enabled=True)
    db = FakeDb()
    import db as db_mod

    monkeypatch.setattr(db_mod, "get_db", lambda: db)
    yield type("R", (), {"cfg": staticmethod(_cfg), "db": db})
    llm_provider.invalidate()


def _connect(db, uid="u1", **doc):
    openai_auth._token_ref(db, uid).set({"mode": "oidc", **doc})


def test_everyone_is_gemini_by_default(routing):
    assert llm_provider.route_for("u1") is None
    assert llm_provider.provider_for("u1") == "gemini"
    assert llm_provider.route_for(None) is None


def test_the_flag_off_means_gemini_even_when_a_connection_exists(routing):
    _connect(routing.db)
    routing.cfg(chatgpt_signin_enabled=False)
    llm_provider.invalidate()
    assert llm_provider.route_for("u1") is None


def test_a_connected_user_routes_to_openai_on_plan_billing(routing):
    _connect(routing.db)
    route = llm_provider.route_for("u1")
    assert route == llm_provider.Route("u1", "plan", "openai")
    assert llm_provider.provider_for("u1") == "openai"
    assert llm_provider.route_for("other") is None  # per-user, not global


def test_api_key_mode_routes_on_api_billing(routing):
    _connect(routing.db, mode="api_key")
    assert llm_provider.route_for("u1").billing == "api"


def test_routing_is_cached_and_invalidated(routing):
    assert llm_provider.route_for("u1") is None
    _connect(routing.db)
    assert llm_provider.route_for("u1") is None  # still cached
    llm_provider.invalidate("u1")
    assert llm_provider.route_for("u1") is not None
    openai_auth.disconnect(routing.db, "u1")  # invalidates
    assert llm_provider.route_for("u1") is None


def test_a_lookup_failure_degrades_to_gemini(routing, monkeypatch):
    def boom(uid):
        raise RuntimeError("firestore down")

    monkeypatch.setattr(llm_provider, "_lookup", boom)
    assert llm_provider.route_for("u1") is None


# ================================================= gemini.py dispatch seam
class _Gem:
    text = '{"from": "gemini"}'


@pytest.fixture
def gemini_stub(monkeypatch):
    monkeypatch.setattr(gemini, "_client", lambda: object())

    async def fake_generate(client, **kw):
        return _Gem()

    monkeypatch.setattr(gemini, "_generate", fake_generate)
    monkeypatch.setattr(token_ledger, "check", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)


def test_gemini_is_untouched_when_there_is_no_route(monkeypatch, gemini_stub):
    monkeypatch.setattr(llm_provider, "route_for", lambda uid: None)
    assert run(gemini.generate_json("c", "s", uid="u1")) == {"from": "gemini"}


def test_a_routed_user_is_served_by_openai(monkeypatch, gemini_stub):
    monkeypatch.setattr(llm_provider, "route_for", lambda uid: PLAN)

    async def fake(route, *a, **k):
        return {"from": "openai", "billing": route.billing}

    monkeypatch.setattr(openai_provider, "generate_json", fake)
    assert run(gemini.generate_json("c", "s", uid="u1")) == {
        "from": "openai", "billing": "plan"}


def test_an_unavailable_openai_falls_back_to_gemini(monkeypatch, gemini_stub):
    monkeypatch.setattr(llm_provider, "route_for", lambda uid: PLAN)

    async def unavailable(route, *a, **k):
        raise openai_client.ProviderUnavailable("plan lacks access")

    monkeypatch.setattr(openai_provider, "generate_json", unavailable)
    assert run(gemini.generate_json("c", "s", uid="u1")) == {"from": "gemini"}


def test_plan_exhaustion_is_not_silently_rerouted(monkeypatch, gemini_stub):
    monkeypatch.setattr(llm_provider, "route_for", lambda uid: PLAN)

    async def capped(route, *a, **k):
        raise token_ledger.ProviderLimitReached("weekly cap")

    monkeypatch.setattr(openai_provider, "generate_json", capped)
    with pytest.raises(token_ledger.TokenCapExceeded):
        run(gemini.generate_json("c", "s", uid="u1"))


def test_each_public_path_dispatches_and_falls_back(monkeypatch, gemini_stub):
    monkeypatch.setattr(llm_provider, "route_for", lambda uid: PLAN)

    async def reply(route, *a, **k):
        yield {"type": "reply", "text": "hi from openai", "tools_used": []}

    async def research(route, *a, **k):
        return "r-openai", [{"url": "u", "title": "t"}]

    async def image(route, *a, **k):
        return b"img", "image/png"

    monkeypatch.setattr(openai_provider, "generate_reply_events", reply)
    monkeypatch.setattr(openai_provider, "research", research)
    monkeypatch.setattr(openai_provider, "generate_image", image)

    events = run(_collect(gemini.generate_reply_events("m", uid="u1")))
    assert events == [{"type": "reply", "text": "hi from openai", "tools_used": []}]
    assert run(gemini.research("q", uid="u1")) == ("r-openai", [{"url": "u", "title": "t"}])
    assert run(gemini.generate_image("p", uid="u1")) == (b"img", "image/png")
    # edit_image rides generate_image
    assert run(gemini.edit_image(b"x", "image/png", "brighten", uid="u1")) == (
        b"img", "image/png")


def test_call_label_names_who_a_deep_dive_researched():
    assert gemini._call_label("web_search", {}) is None
    assert gemini._call_label(
        "deep_dive", {"full_name": "Ada", "subject": "self"}
    ) == "Researched yourself online"
    assert gemini._call_label(
        "deep_dive", {"full_name": "Ada", "subject": "match"}
    ) == "Researched Ada online"
