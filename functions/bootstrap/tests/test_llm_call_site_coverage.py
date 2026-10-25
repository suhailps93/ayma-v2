"""Every Gemini call site is either routed through ``llm_routing`` or listed
here as a justified exception, so a new direct call cannot slip in silently.

The scan is static (AST) over every non-test module in ``functions/bootstrap``.
"""

from __future__ import annotations

import ast
from pathlib import Path

import gemini
from config import CONFIG

ROOT = Path(__file__).resolve().parent.parent

# Wrappers whose routing is decided inside gemini.py by llm_routing.route_for.
ROUTED_WRAPPERS = {"generate_json", "generate_reply", "generate_reply_events"}

# Functions in gemini.py that may call the Google client directly (_generate /
# _client). Anything else doing so is an unrouted call.
GEMINI_DIRECT = {
    "warmup": "unmetered Vertex client warm-up ping (cold-start only)",
    "generate_reply_events": "Vertex branch, reached only after route_for('chat') or as the fallback",
    "generate_json": "Vertex branch, reached only after route_for('json'|'vision') or as the fallback",
    "research": "Google Search + URL-context grounding: not on the gateway",
    "generate_image": "image generation model: not on the gateway",
}

# Modules outside gemini.py that call the Google client / REST APIs directly.
EXCEPTIONS = {
    "gemini_batch.py": "Batch API (half price, no Inference batch tier)",
    "voice_preview.py": "Gemini TTS: no TTS endpoint on the gateway",
    "media_embed.py": "gemini-embedding-2 vectors: no embeddings endpoint, stored index is model-bound",
    "reverse_image_search.py": "Cloud Vision web detection, not Gemini",
    "agent.py": "Voice worker owns its Live session (routed by route_for('voice'))",
    "gemini.py": "the router itself (see GEMINI_DIRECT)",
    "inference_llm.py": "the gateway client itself",
    "config.py": "mentions the TTS/image models in comments, makes no calls",
    "token_ledger.py": "pricing table label for embeddings, makes no calls",
}

# Callers of gemini.research (grounded) stay on Vertex by design.
RESEARCH_CALLERS = {
    "gemini.py": "chat web_search tool",
    "deep_dive.py": "grounded public-profile / deep dive research",
    "deep_dive_public_profiles.py": "grounded public-profile search",
}

# Modules allowed to touch a Google client or genai types at all.
GOOGLE_CLIENT_MARKERS = (
    "gemini._client", "gemini._generate", "genai.Client", "embedContent",
    "batches.create", "batches.get", "generate_content",
)


def _modules():
    for p in sorted(ROOT.glob("**/*.py")):
        rel = p.relative_to(ROOT)
        if rel.parts[0] in {"tests", "scripts", ".venv", "venv"}:
            continue
        yield p, rel.as_posix()


def _source(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def test_no_unlisted_module_calls_a_google_client_directly():
    offenders = []
    for p, rel in _modules():
        if rel in EXCEPTIONS:
            continue
        src = _source(p)
        code_hits = [m for m in GOOGLE_CLIENT_MARKERS if m in src]
        if code_hits:
            offenders.append((rel, code_hits))
    assert not offenders, (
        "Direct Google client use outside the justified EXCEPTIONS list: "
        f"{offenders}. Route it through gemini.generate_json/generate_reply "
        "(llm_routing) or add a justified exception."
    )


def test_gemini_direct_google_calls_are_only_in_listed_functions():
    tree = ast.parse(_source(ROOT / "gemini.py"))
    found = set()
    for fn in [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]:
        for node in ast.walk(fn):
            if isinstance(node, ast.Call):
                name = ast.unparse(node.func)
                if name in {"_generate", "_client"}:
                    found.add(fn.name)
    assert found <= set(GEMINI_DIRECT), (
        f"gemini.py functions calling Google directly but not justified: "
        f"{sorted(found - set(GEMINI_DIRECT))}"
    )


def test_routed_wrappers_consult_llm_routing_with_the_caller_uid():
    for name in ("generate_json", "generate_reply_events"):
        src = ast.unparse(
            next(n for n in ast.parse(_source(ROOT / "gemini.py")).body
                 if getattr(n, "name", "") == name)
        )
        assert "llm_routing.route_for(" in src, name
        assert ", uid)" in src, f"{name} must pass uid so allowlists work"
    assert hasattr(gemini, "generate_reply")  # delegates to generate_reply_events


def test_research_callers_are_the_documented_grounded_ones():
    callers = set()
    for p, rel in _modules():
        for node in ast.walk(ast.parse(_source(p))):
            if (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr == "research"
                and ast.unparse(node.func.value) in {"gemini", "self"}
            ) or (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name)
                and node.func.id == "research"
                and rel == "gemini.py"
            ):
                callers.add(rel)
    assert callers <= set(RESEARCH_CALLERS), (
        f"unlisted gemini.research callers (stay on Vertex): "
        f"{sorted(callers - set(RESEARCH_CALLERS))}"
    )


def test_all_other_llm_use_goes_through_the_routed_wrappers():
    """Any module calling ``gemini.<fn>`` may only use the routed wrappers or
    the documented exception functions."""
    allowed = ROUTED_WRAPPERS | {"research", "generate_image", "edit_image", "warmup"}
    bad = []
    for p, rel in _modules():
        for node in ast.walk(ast.parse(_source(p))):
            if (
                isinstance(node, ast.Attribute)
                and isinstance(node.value, ast.Name)
                and node.value.id == "gemini"
                and not node.attr.startswith("_")
                and node.attr in _public_llm_entrypoints()
                and node.attr not in allowed
            ):
                bad.append((rel, node.attr))
    assert not bad, bad


def _public_llm_entrypoints() -> set[str]:
    return {
        n for n in dir(gemini)
        if n.startswith(("generate", "research", "edit_", "stream", "embed"))
    }


def test_branch_defaults_send_every_group_to_inference():
    assert CONFIG.llm_route_json == "inference"
    assert CONFIG.llm_route_vision == "inference"
    assert CONFIG.llm_route_chat == "inference"
    assert CONFIG.llm_inference_fallback is False


def test_worker_image_requirements_include_the_gateway_client():
    for name in ("requirements.txt", "requirements-agent.txt", "requirements-agent-inference.txt"):
        assert "openai==" in (ROOT / name).read_text(encoding="utf-8"), name
