"""Side-by-side quality / cost / latency comparison: Vertex vs LiveKit Inference.

Runs the SAME prompts through both routes using the production code paths
(``gemini.generate_json`` / ``gemini.generate_reply``), then has a judge model
(always on Vertex) pick a winner per case with the order randomised.

    cd functions/bootstrap
    export LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=...   # from Secret Manager
    # Vertex needs ADC (gcloud auth application-default login)
    INFERENCE_JSON_MODEL=google/gemini-3.8-flash \\
    INFERENCE_CHAT_MODEL=google/gemini-3.8-flash \\
        python scripts/llm_side_by_side.py [--only chat,matching,wiki] [--out report.json]

Cases: the persona regression scenarios (``persona_eval_scenarios.json``) for
chat, the matching-skill prompt over synthetic profile pairs, and the wiki
ingest prompt over synthetic transcripts (``scripts/llm_ab_fixtures.json``).
Matching is also run twice on Vertex to measure its own run-to-run noise, so a
score difference can be judged against that baseline. No credentials are read
from anywhere but the environment; nothing is written except ``--out``.
"""

from __future__ import annotations

import argparse
import asyncio
import dataclasses
import json
import random
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import gemini  # noqa: E402
import llm_routing  # noqa: E402
import matching_skill  # noqa: E402
import persona_evolution  # noqa: E402
import prompt as prompt_mod  # noqa: E402
import token_ledger  # noqa: E402
import wiki_ingest  # noqa: E402
from config import CONFIG  # noqa: E402
from transcript import Turn  # noqa: E402

_DIR = Path(__file__).resolve().parent
_FIXTURES = json.loads((_DIR / "llm_ab_fixtures.json").read_text(encoding="utf-8"))
_JUDGE_PROMPT = (_DIR.parent / "prompts" / "llm_ab_judge.md").read_text(
    encoding="utf-8"
)
_JUDGE_SCHEMA = {
    "type": "object",
    "properties": {
        "winner": {"type": "string", "enum": ["1", "2", "tie"]},
        "score_1": {"type": "number"},
        "score_2": {"type": "number"},
        "reason": {"type": "string"},
    },
    "required": ["winner", "score_1", "score_2", "reason"],
}

_USAGE: dict[str, dict[str, float]] = {}
_CURRENT_ROUTE = {"name": "vertex"}


def _record(uid, feature, response, *, model=None, session_id=None, **_ignored):
    inp, out, _total, cached = token_ledger._usage_from_response(response)
    bucket = _USAGE.setdefault(
        _CURRENT_ROUTE["name"],
        {"calls": 0, "in": 0, "out": 0, "usd": 0.0, "seconds": 0.0},
    )
    bucket["calls"] += 1
    bucket["in"] += inp
    bucket["out"] += out
    bucket["usd"] += token_ledger.cost_usd_for(
        feature, inp, out, cached_input_tokens=cached, model=model
    )


token_ledger.record = _record
llm_routing._read_doc = lambda: {}  # env only: never read prod routing


def _set_route(name: str) -> None:
    _CURRENT_ROUTE["name"] = name
    gemini.CONFIG = llm_routing.CONFIG = dataclasses.replace(
        CONFIG,
        llm_percent_json=100, llm_percent_vision=100, llm_percent_chat=100,
        llm_route_json=name,
        llm_route_vision=name,
        llm_route_chat=name,
        llm_inference_fallback=False,  # a silent fallback would void the test
        gemini_web_search=False,  # grounding is not what is being compared
    )


async def _timed(route: str, coro):
    _set_route(route)
    t0 = time.monotonic()
    try:
        return await coro
    finally:
        _USAGE.setdefault(
            route, {"calls": 0, "in": 0, "out": 0, "usd": 0.0, "seconds": 0.0}
        )["seconds"] += time.monotonic() - t0


async def _judge(task: str, instructions: str, inp: str, out1: str, out2: str):
    _set_route("vertex")
    _CURRENT_ROUTE["name"] = "judge"
    order = random.random() < 0.5
    a, b = (out1, out2) if order else (out2, out1)
    verdict = await gemini.generate_json(
        f"TASK: {task}\n\nINSTRUCTIONS GIVEN TO THE MODELS:\n{instructions}\n\n"
        f"INPUT:\n{inp}\n\nOUTPUT 1:\n{a}\n\nOUTPUT 2:\n{b}",
        system_prompt=_JUDGE_PROMPT,
        response_schema=_JUDGE_SCHEMA,
        enforce_cap=False,
        temperature=0.0,
    )
    w = verdict["winner"]
    if w != "tie":
        w = "vertex" if (w == "1") == order else "inference"
    return {
        "winner": w,
        "vertex_score": verdict["score_1"] if order else verdict["score_2"],
        "inference_score": verdict["score_2"] if order else verdict["score_1"],
        "reason": verdict["reason"],
    }


async def _safe(case: str, coro) -> dict:
    """One failing case (a Vertex timeout, a 429) is a result, not a crash."""
    try:
        row = await coro
        print(f"  done {case}: {row.get('winner')}", flush=True)
        return row
    except Exception as exc:  # noqa: BLE001 - recorded in the report
        print(f"  FAILED {case}: {type(exc).__name__}: {exc}", flush=True)
        return {"case": case, "error": f"{type(exc).__name__}: {exc}"}


async def _chat_case(sc: dict) -> dict:
    history = [
        Turn(role=str(t.get("role", "")), text=str(t.get("text", "")))
        for t in sc.get("history", [])
    ]
    system_prompt = prompt_mod.compose_system_prompt(recent_turns=history)

    async def reply():
        return (
            await gemini.generate_reply(sc["message"], system_prompt=system_prompt)
        ).text

    v = await _timed("vertex", reply())
    i = await _timed("inference", reply())
    j = await _judge(
        f"Ayma chat reply. Scenario focus: {sc.get('focus', '')}",
        system_prompt, sc["message"], v, i,
    )
    return {"case": f"chat/{sc['id']}", "vertex": v, "inference": i, **j}


async def _matching_case(pair: dict) -> dict:
    keys = matching_skill._DIM_KEYS
    contents = matching_skill._llm_contents(
        pair["wiki_a"], pair["wiki_b"], [], [], pair["intent"],
        {"dimensions": {}, "gate_failures": []}, keys,
    )

    async def run():
        return await matching_skill._run_llm(contents, keys, uid="ab-eval")

    v1 = await _timed("vertex", run())
    v2 = await _timed("vertex", run())
    i1 = await _timed("inference", run())

    def scores(r):
        return {d["key"]: float(d["score"]) for d in r.get("dimensions", [])}

    s1, s2, si = scores(v1), scores(v2), scores(i1)
    common = [k for k in keys if k in s1 and k in s2 and k in si]
    noise = statistics.mean(abs(s1[k] - s2[k]) for k in common) if common else None
    diff = statistics.mean(abs(s1[k] - si[k]) for k in common) if common else None
    j = await _judge(
        "Compatibility scoring + narrative explanation for a dating match.",
        matching_skill._load_prompt(), contents,
        json.dumps(v1, ensure_ascii=False, indent=1),
        json.dumps(i1, ensure_ascii=False, indent=1),
    )
    return {
        "case": f"matching/{pair['id']}",
        "dims_scored_vertex": len(s1), "dims_scored_inference": len(si),
        "mean_abs_score_diff_vertex_vs_inference": diff,
        "mean_abs_score_diff_vertex_vs_vertex_noise": noise,
        "vertex_scores": s1, "inference_scores": si, **j,
    }


async def _wiki_case(tr: dict) -> dict:
    turns = [Turn(role=t["role"], text=t["text"]) for t in tr["turns"]]
    contents = wiki_ingest._build_contents(turns, [])

    async def run():
        return await gemini.generate_json(
            contents, system_prompt=wiki_ingest.load_ingest_prompt(),
            response_schema=wiki_ingest._RESPONSE_SCHEMA, enforce_cap=False,
        )

    v = await _timed("vertex", run())
    i = await _timed("inference", run())
    j = await _judge(
        "Wiki compilation: turn a conversation into structured profile pages.",
        wiki_ingest.load_ingest_prompt(), contents,
        json.dumps(v, ensure_ascii=False, indent=1),
        json.dumps(i, ensure_ascii=False, indent=1),
    )
    return {"case": f"wiki/{tr['id']}", **j}


async def run_chat() -> list[dict]:
    return [
        await _safe(f"chat/{sc['id']}", _chat_case(sc))
        for sc in persona_evolution.load_eval_scenarios()
    ]


async def run_matching() -> list[dict]:
    return [
        await _safe(f"matching/{p['id']}", _matching_case(p))
        for p in _FIXTURES["match_pairs"]
    ]


async def run_wiki() -> list[dict]:
    return [
        await _safe(f"wiki/{t['id']}", _wiki_case(t))
        for t in _FIXTURES["transcripts"]
    ]


def _summarise(all_rows: list[dict]) -> dict:
    rows = [r for r in all_rows if "error" not in r]
    wins = {"vertex": 0, "inference": 0, "tie": 0}
    for r in rows:
        wins[r["winner"]] += 1
    if not rows:
        return {"cases": len(all_rows), "errors": len(all_rows)}
    return {
        "cases": len(all_rows),
        "errors": len(all_rows) - len(rows),
        "wins": wins,
        "mean_score_vertex": statistics.mean(r["vertex_score"] for r in rows),
        "mean_score_inference": statistics.mean(r["inference_score"] for r in rows),
    }


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="chat,matching,wiki")
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    wanted = set(args.only.split(","))
    print(f"vertex={CONFIG.gemini_model} inference_json={CONFIG.inference_json_model} "
          f"inference_chat={CONFIG.inference_chat_model}")
    report: dict = {}
    for name, fn in (("chat", run_chat), ("matching", run_matching), ("wiki", run_wiki)):
        if name in wanted:
            rows = await fn()
            report[name] = {"summary": _summarise(rows), "rows": rows}
            print(name, json.dumps(report[name]["summary"]))
    report["usage_by_route"] = _USAGE
    print(json.dumps(_USAGE, indent=1))
    if args.out:
        Path(args.out).write_text(json.dumps(report, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    asyncio.run(main())
