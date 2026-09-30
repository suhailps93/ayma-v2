"""OpenAI implementations of the ``gemini.py`` public surface, used per user
when :func:`llm_provider.route_for` returns a route (docs/chatgpt-provider.md).

Same function contracts as ``gemini.py`` — text reply (+ tools, status
events), grounded research, structured JSON, image generate/edit — so no call
site changes. Everything speaks the Responses API (``/v1/responses``): it is
the endpoint OpenAI's ChatGPT-plan tokens are documented to cover, and it
carries function tools, ``web_search`` and ``image_generation`` in one shape.

Metering: every call is recorded through ``token_ledger.record_openai`` with
the route's ``billing`` — ``plan`` writes no Ayma credit / real-money charge.
Model ids come only from ``config.py``.
"""

from __future__ import annotations

import base64
import inspect
import json
import logging
import re

import gemini
import llm_provider
import openai_client
import token_ledger
from config import CONFIG
from tool_labels import working_label as _working_label

logger = logging.getLogger("ayma.openai_provider")

# Reasoning tokens count against max_output_tokens on OpenAI reasoning models,
# so the visible-answer budgets are larger than Gemini's.
_REPLY_MAX_TOKENS = 3072
_JSON_MAX_TOKENS = 8192
_MAX_TOOL_ROUNDS = 3

_FENCE = re.compile(r"^```(?:json)?\s*|\s*```$", re.IGNORECASE)


# ------------------------------------------------------------------ helpers
def _b64_image(image: tuple[bytes, str]) -> dict:
    data, mime = image
    return {
        "type": "input_image",
        "image_url": f"data:{mime};base64,{base64.b64encode(data).decode()}",
    }


def _user_message(text: str, images: list[tuple[bytes, str]] | None = None) -> dict:
    content = [_b64_image(i) for i in (images or [])]
    content.append({"type": "input_text", "text": text})
    return {"role": "user", "content": content}


def _base(model: str, instructions: str | None, max_tokens: int) -> dict:
    body: dict = {
        "model": model,
        "store": False,
        "max_output_tokens": max_tokens,
    }
    if instructions:
        body["instructions"] = instructions
    effort = (CONFIG.openai_reasoning_effort or "").strip().lower()
    if effort in ("minimal", "low", "medium", "high"):
        body["reasoning"] = {"effort": effort}
    return body


def _function_tools(declarations: list[dict] | None) -> list[dict]:
    return [
        {
            "type": "function",
            "name": d["name"],
            "description": d.get("description", ""),
            "parameters": d.get("parameters")
            or {"type": "object", "properties": {}},
            "strict": False,
        }
        for d in (declarations or [])
    ]


def _output(resp: dict) -> list[dict]:
    return [i for i in (resp.get("output") or []) if isinstance(i, dict)]


def _text(resp: dict) -> str:
    parts: list[str] = []
    for item in _output(resp):
        if item.get("type") != "message":
            continue
        for c in item.get("content") or []:
            if isinstance(c, dict) and c.get("type") == "output_text":
                parts.append(c.get("text") or "")
    return "".join(parts).strip() or (resp.get("output_text") or "").strip()


def _count(resp: dict, item_type: str) -> int:
    return sum(1 for i in _output(resp) if i.get("type") == item_type)


def _record(
    route: llm_provider.Route,
    feature: str,
    resp: dict,
    model: str,
    *,
    session_id: str | None = None,
) -> None:
    searches = _count(resp, "web_search_call")
    token_ledger.record_openai(
        route.uid,
        feature,
        resp.get("usage") or {},
        model=model,
        billing=route.billing,
        session_id=session_id,
        extra_cost_usd=searches * token_ledger.OPENAI_WEB_SEARCH_USD_PER_CALL,
    )


def _check(route: llm_provider.Route) -> None:
    token_ledger.check(route.uid, billing=route.billing)


# --------------------------------------------------------------------- reply
async def generate_reply_events(
    route: llm_provider.Route,
    message: str,
    system_prompt: str | None = None,
    tool_declarations: list[dict] | None = None,
    tool_fns: dict | None = None,
    *,
    image: tuple[bytes, str] | None = None,
    uid: str | None = None,
    feature: str = "misc",
    session_id: str = "",
):
    """Mirror of :func:`gemini.generate_reply_events` (same event shapes)."""
    tools = _function_tools(tool_declarations)
    if CONFIG.openai_web_search:
        tools.append({"type": "web_search"})

    model = CONFIG.openai_model
    _check(route)
    input_items: list[dict] = [
        _user_message(message, [image] if image is not None else None)
    ]
    used: list[str] = []
    seen: set[str] = set()

    def _note(name: str, label: str | None = None) -> None:
        key = label or name
        if key not in seen:
            seen.add(key)
            used.append(label or gemini._tool_label(name))

    yield {"type": "status", "label": "Thinking…"}
    resp: dict = {}
    for round_no in range(_MAX_TOOL_ROUNDS + 1):
        body = _base(model, system_prompt, _REPLY_MAX_TOKENS)
        body["input"] = input_items
        if tools:
            body["tools"] = tools
        resp = await openai_client.responses(route, body)
        _record(route, feature, resp, model, session_id=session_id or None)
        if _count(resp, "web_search_call"):
            _note("web_search")

        calls = [i for i in _output(resp) if i.get("type") == "function_call"]
        if not calls or not tool_fns or round_no == _MAX_TOOL_ROUNDS:
            break
        # Echo the model's calls back (id stripped: with store=false the
        # item ids are not resolvable server-side), then the results.
        for call in calls:
            input_items.append(
                {
                    "type": "function_call",
                    "call_id": call.get("call_id"),
                    "name": call.get("name"),
                    "arguments": call.get("arguments") or "{}",
                }
            )
        yield {"type": "status", "label": "Working…"}
        for call in calls:
            name = str(call.get("name") or "")
            try:
                args = json.loads(call.get("arguments") or "{}")
                if not isinstance(args, dict):
                    args = {}
            except ValueError:
                args = {}
            _note(name, gemini._call_label(name, args))
            yield {"type": "status", "label": _working_label(name)}
            fn = tool_fns.get(name)
            try:
                result = fn(**args) if fn else "unknown tool"
                if inspect.isawaitable(result):
                    result = await result
            except Exception as exc:  # noqa: BLE001 - report to the model
                result = f"error: {exc}"
            input_items.append(
                {
                    "type": "function_call_output",
                    "call_id": call.get("call_id"),
                    "output": result if isinstance(result, str)
                    else json.dumps(result, default=str),
                }
            )
        yield {"type": "status", "label": "Writing…"}

    text = gemini.strip_inline_refs(_text(resp))
    if not text:
        raise RuntimeError("OpenAI returned an empty response.")
    yield {"type": "reply", "text": text, "tools_used": used}


# ------------------------------------------------------------------ research
def _sources(resp: dict) -> list[dict]:
    out: list[dict] = []
    seen: set[str] = set()
    for item in _output(resp):
        if item.get("type") != "message":
            continue
        for c in item.get("content") or []:
            for ann in (c.get("annotations") or []) if isinstance(c, dict) else []:
                if ann.get("type") != "url_citation":
                    continue
                url = ann.get("url")
                if url and url not in seen:
                    seen.add(url)
                    out.append({"url": url, "title": ann.get("title") or url})
    return out


async def research(
    route: llm_provider.Route,
    prompt: str,
    system_prompt: str | None = None,
    *,
    uid: str | None = None,
    feature: str = "misc",
    max_output_tokens: int = 4096,
) -> tuple[str, list[dict]]:
    _check(route)
    model = CONFIG.openai_model
    body = _base(model, system_prompt, max(max_output_tokens * 2, 2048))
    body["input"] = [_user_message(prompt)]
    body["tools"] = [{"type": "web_search"}]
    resp = await openai_client.responses(route, body)
    _record(route, feature, resp, model)
    return gemini.strip_inline_refs(_text(resp)), _sources(resp)


# ---------------------------------------------------------------------- json
def _json_instructions(system_prompt: str, schema: dict | None) -> str:
    tail = "Respond with a single JSON value and nothing else."
    if schema:
        tail += (
            " It must conform to this JSON Schema:\n"
            + json.dumps(schema, separators=(",", ":"), default=str)
        )
    return f"{system_prompt}\n\n{tail}"


async def generate_json(
    route: llm_provider.Route,
    contents: str,
    system_prompt: str,
    response_schema: dict | None = None,
    image: tuple[bytes, str] | None = None,
    *,
    images: list[tuple[bytes, str]] | None = None,
    uid: str | None = None,
    feature: str = "misc",
    enforce_cap: bool = True,
    temperature: float = 0.2,
    session_id: str = "",
) -> object:
    if enforce_cap:
        _check(route)
    photos = list(images or ([image] if image is not None else []))
    model = CONFIG.openai_model
    body = _base(model, _json_instructions(system_prompt, response_schema),
                 _JSON_MAX_TOKENS)
    body["input"] = [_user_message(f"{contents}\n\nReturn JSON.", photos)]
    body["text"] = {"format": {"type": "json_object"}}
    resp = await openai_client.responses(route, body)
    _record(route, feature, resp, model, session_id=session_id or None)
    text = _FENCE.sub("", _text(resp)).strip()
    if not text:
        raise RuntimeError("OpenAI returned an empty JSON response.")
    return json.loads(text)


# --------------------------------------------------------------------- image
async def generate_image(
    route: llm_provider.Route,
    prompt: str,
    *,
    image: tuple[bytes, str] | None = None,
    uid: str | None = None,
    feature: str = "misc",
) -> tuple[bytes, str]:
    _check(route)
    model = CONFIG.openai_model
    body = _base(model, None, _REPLY_MAX_TOKENS)
    body["input"] = [_user_message(prompt, [image] if image is not None else None)]
    body["tools"] = [
        {
            "type": "image_generation",
            "model": CONFIG.openai_image_model,
            "output_format": "png",
        }
    ]
    body["tool_choice"] = {"type": "image_generation"}
    resp = await openai_client.responses(route, body)
    # The response's top-level usage is the orchestrating text model's; the
    # image tool's own tokens (when reported) are priced at the image model.
    _record(route, feature, resp, model)
    image_usage = ((resp.get("tool_usage") or {}).get("image_gen")) or {}
    if image_usage:
        token_ledger.record_openai(
            route.uid, feature, image_usage,
            model=CONFIG.openai_image_model, billing=route.billing,
        )
    for item in _output(resp):
        if item.get("type") == "image_generation_call" and item.get("result"):
            fmt = (item.get("output_format") or "png").lower()
            mime = "image/jpeg" if fmt in ("jpg", "jpeg") else f"image/{fmt}"
            return base64.b64decode(item["result"]), mime
    refusal = gemini.strip_inline_refs(_text(resp))
    raise RuntimeError(refusal or "OpenAI did not return an image")
