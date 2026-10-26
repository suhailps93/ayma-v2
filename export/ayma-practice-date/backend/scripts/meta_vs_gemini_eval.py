#!/usr/bin/env python3
"""Meta Muse Spark vs Gemini — side-by-side eval (hackathon Deliverable A).

Runs a fixed set of matching profile-pairs and report prompts through BOTH
providers and prints a comparison, so Muse Spark earns the switch on evidence.

Live mode needs ``META_API_KEY`` (and, for Gemini, ADC / ``GOOGLE_API_KEY``)
in the environment; it calls both providers directly through
``llm_provider.py`` with the real, locked models from ``config.py``.

``--dry-run`` (default when ``META_API_KEY`` is unset) makes no network calls:
it prints the exact request each provider WOULD send — model id, mapped
``response_format``, message shape — so the wiring can be verified now, before
the key lands.

Usage::

    cd functions/bootstrap
    python scripts/meta_vs_gemini_eval.py            # dry-run if no key
    python scripts/meta_vs_gemini_eval.py --live      # force live
    python scripts/meta_vs_gemini_eval.py --out /tmp/eval.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import llm_provider  # noqa: E402
from config import CONFIG  # noqa: E402
from llm_provider import (  # noqa: E402
    GeminiProvider,
    MetaProvider,
    _response_format,
    _user_content,
)

# Fixed, synthetic fixtures — no user data. Two matching pairs and two report
# prompts, each with a small JSON schema the provider must fill.
_MATCH_SCHEMA = {
    "type": "object",
    "properties": {
        "score": {"type": "number"},
        "rationale": {"type": "string"},
        "shared": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["score", "rationale"],
}
_REPORT_SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string"},
        "strengths": {"type": "array", "items": {"type": "string"}},
        "improvements": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["verdict"],
}

_SYSTEM_MATCH = (
    "You score romantic compatibility between two people on a 0-100 scale. "
    "Return only the JSON object the schema asks for."
)
_SYSTEM_REPORT = (
    "You write a short, honest, kind profile report. Return only the JSON "
    "object the schema asks for."
)

FIXTURES = [
    {
        "name": "match: hiker + climber",
        "system": _SYSTEM_MATCH,
        "schema": _MATCH_SCHEMA,
        "contents": (
            "Person A: 29, loves trail running, cooks Thai food, wants kids. "
            "Person B: 31, rock climber, vegetarian, undecided on kids. "
            "Score their compatibility."
        ),
    },
    {
        "name": "match: homebody + traveller",
        "system": _SYSTEM_MATCH,
        "schema": _MATCH_SCHEMA,
        "contents": (
            "Person A: 35, introvert, reads sci-fi, saves aggressively. "
            "Person B: 34, digital nomad, extrovert, spends freely. "
            "Score their compatibility."
        ),
    },
    {
        "name": "report: terse bio",
        "system": _SYSTEM_REPORT,
        "schema": _REPORT_SCHEMA,
        "contents": "Profile bio: 'hey. ask me anything.' Two photos, no prompts answered.",
    },
    {
        "name": "report: rich bio",
        "system": _SYSTEM_REPORT,
        "schema": _REPORT_SCHEMA,
        "contents": (
            "Profile bio: 'Pediatric nurse, marathoner, terrible at chess but "
            "trying. Looking for someone to explore taco trucks with.' Six "
            "photos, all prompts answered thoughtfully."
        ),
    },
]


def _describe_request(provider_name: str, fx: dict) -> dict:
    """What a provider WOULD send for this fixture (dry-run view)."""
    if provider_name == "meta":
        return {
            "provider": "meta",
            "model": CONFIG.meta_chat_model,
            "base_url": CONFIG.meta_api_base_url,
            "messages": [
                {"role": "system", "content": fx["system"]},
                {"role": "user", "content": _user_content(fx["contents"], [])},
            ],
            "response_format": _response_format(fx["schema"], "eval"),
        }
    return {
        "provider": "gemini",
        "model": CONFIG.gemini_model,
        "system_instruction": fx["system"],
        "response_mime_type": "application/json",
        "response_schema": fx["schema"],
    }


async def _run_live(provider, fx: dict) -> dict:
    t0 = time.monotonic()
    try:
        out = await provider.generate_json(
            fx["contents"], fx["system"], response_schema=fx["schema"],
            uid=None, feature="eval", enforce_cap=False, temperature=0.0,
        )
        return {"ok": True, "seconds": round(time.monotonic() - t0, 2), "output": out}
    except Exception as exc:  # noqa: BLE001 - report both sides' failures
        return {"ok": False, "seconds": round(time.monotonic() - t0, 2),
                "error": f"{type(exc).__name__}: {exc}"}


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", action="store_true", help="force live calls")
    ap.add_argument("--dry-run", action="store_true", help="force dry-run")
    ap.add_argument("--out", help="write the full JSON report here")
    args = ap.parse_args()

    has_key = bool(os.getenv("META_API_KEY"))
    live = args.live or (has_key and not args.dry_run)

    print(f"Meta vs Gemini eval — mode={'LIVE' if live else 'DRY-RUN'}")
    print(f"  meta model : {CONFIG.meta_chat_model} @ {CONFIG.meta_api_base_url}")
    print(f"  gemini model: {CONFIG.gemini_model}")
    if live and not has_key:
        print("  ERROR: --live requires META_API_KEY in the environment.")
        return 2
    if not live:
        print("  (no META_API_KEY — showing the requests each side would send)\n")

    gemini_p = GeminiProvider()
    # No fallback here — the eval must measure Meta on its own.
    meta_p = MetaProvider(fallback=None)

    report: list[dict] = []
    for fx in FIXTURES:
        print(f"\n=== {fx['name']} ===")
        if live:
            gem, meta = await asyncio.gather(
                _run_live(gemini_p, fx), _run_live(meta_p, fx)
            )
            for label, r in (("gemini", gem), ("meta", meta)):
                status = f"ok {r['seconds']}s" if r["ok"] else f"FAILED {r.get('error')}"
                print(f"  {label:7}: {status}")
                if r["ok"]:
                    print(f"           {json.dumps(r['output'])[:200]}")
            report.append({"fixture": fx["name"], "gemini": gem, "meta": meta})
        else:
            gem_req = _describe_request("gemini", fx)
            meta_req = _describe_request("meta", fx)
            print(f"  gemini -> {gem_req['model']}, response_schema set")
            print(f"  meta   -> {meta_req['model']}, "
                  f"response_format={meta_req['response_format']['type']}")
            report.append({"fixture": fx["name"],
                           "gemini_request": gem_req, "meta_request": meta_req})

    if args.out:
        Path(args.out).write_text(json.dumps(report, indent=2))
        print(f"\nWrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
