"""LiveKit-only enforcement: no served module may construct a direct-Google
inference client. Static scans over every non-test module in
``functions/bootstrap``, so a new direct call cannot slip in silently.

Founder rule (2026-11-04, permanent): ALL inference goes through LiveKit.
The ``google.cloud`` / ``google.auth`` clients that remain (Firestore,
Storage, Auth, Cloud Vision web detection, Vertex AI Search retrieval) are
data-plane / retrieval APIs, not Gemini inference — see
``docs/DIRECT_GOOGLE_KILL_AUDIT.md``.
"""

from __future__ import annotations

import ast
from pathlib import Path

import gemini
import llm_routing
from config import CONFIG

ROOT = Path(__file__).resolve().parent.parent

# The ONE founder-authorized direct-Google inference exception, scoped to
# IMAGE GENERATION only (founder decision 2026-11-08; AGENTS.md "scoped
# exception" note). ``image_gen.py`` is the only served module permitted to
# construct a direct image client — ``gemini.generate_image`` /
# ``gemini.edit_image`` are its public face and route through it. Every OTHER
# inference path (chat, matching, JSON, vision, voice) stays LiveKit-only and
# is scanned below. Keep this set to image generation alone.
IMAGE_GEN_EXCEPTION = {"image_gen.py"}


def _modules():
    for p in sorted(ROOT.glob("**/*.py")):
        rel = p.relative_to(ROOT)
        if rel.parts[0] in {"tests", "scripts", "tools", ".venv", "venv"}:
            continue
        yield p, rel.as_posix()


def _source(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def _dotted(node) -> str:
    """Dotted path of a call func / attribute chain (``a.b.c``)."""
    try:
        return ast.unparse(node)
    except Exception:  # noqa: BLE001 - unparse is best-effort here
        return ""


def test_no_served_module_imports_google_genai():
    """The genai SDK (Vertex + Developer-API client) is gone from served
    code — only the LiveKit gateway client (``inference_llm``) remains."""
    offenders = []
    for p, rel in _modules():
        if rel in IMAGE_GEN_EXCEPTION:
            continue  # scoped image-generation exception — see IMAGE_GEN_EXCEPTION
        tree = ast.parse(_source(p))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                mods = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom):
                mods = [node.module or ""]
            else:
                continue
            if any(m == "google.genai" or m.startswith("google.genai.")
                   for m in mods):
                offenders.append(rel)
                break
    assert not offenders, (
        f"google.genai imports in served code (all inference must go through "
        f"the LiveKit gateway): {offenders}"
    )


def test_no_served_module_constructs_a_direct_google_client():
    """No ``genai.Client``, no ``vertexai=`` auth kwarg, no Batch API calls,
    no aiplatform REST URL, no direct ``generate_content`` — anywhere in
    served code (comments/docstrings excluded: this is an AST scan)."""
    offenders = []
    for p, rel in _modules():
        if rel in IMAGE_GEN_EXCEPTION:
            continue  # scoped image-generation exception — see IMAGE_GEN_EXCEPTION
        tree = ast.parse(_source(p))
        hits: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                dotted = _dotted(node.func)
                if "genai" in dotted and dotted.endswith("Client"):
                    hits.add(dotted)
                if ".batches." in dotted or dotted.endswith(".batches"):
                    hits.add(dotted)
                attr = node.func.attr if isinstance(
                    node.func, ast.Attribute) else ""
                if attr == "generate_content":
                    hits.add(dotted)
                for kw in node.keywords:
                    if kw.arg == "vertexai":
                        hits.add("vertexai= kwarg")
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                if ("aiplatform.googleapis.com" in node.value
                        or ":embedContent" in node.value):
                    hits.add("aiplatform REST marker")
        if hits:
            offenders.append((rel, sorted(hits)))
    assert not offenders, (
        f"direct-Google inference construction in served code: {offenders}"
    )


def test_gemini_has_no_direct_client_helpers_left():
    """The Vertex/dev client factory and its retry wrapper are deleted —
    nothing can even import them back into a call site. The restored image
    path does NOT bring them back: its one direct call lives in image_gen.py
    (the scoped exception), not here."""
    assert not hasattr(gemini, "_client")
    assert not hasattr(gemini, "_generate")


def test_the_direct_google_exception_is_scoped_to_image_generation():
    """The one direct-Google exception is image generation, and it is narrow:
    exactly the image_gen module is exempt, it really does construct a direct
    image client (so the exemption is load-bearing, not a free pass), and
    gemini.generate_image / edit_image route through it rather than calling
    Google themselves."""
    assert IMAGE_GEN_EXCEPTION == {"image_gen.py"}
    src = _source(ROOT / "image_gen.py")
    tree = ast.parse(src)
    constructs_client = any(
        isinstance(n, ast.Call)
        and _dotted(n.func).endswith("Client")
        and "genai" in _dotted(n.func)
        for n in ast.walk(tree)
    )
    assert constructs_client, "image_gen must hold the real direct call"
    # The public image funcs delegate to image_gen and carry no genai call.
    gsrc = _source(ROOT / "gemini.py")
    for name in ("generate_image", "edit_image"):
        fn = next(
            n for n in ast.parse(gsrc).body if getattr(n, "name", "") == name
        )
        body = ast.unparse(fn)
        assert "genai" not in body and "generate_content" not in body, name
    assert "image_gen" in gsrc


def test_routed_wrappers_are_livekit_only():
    """``generate_json`` / ``generate_reply`` / ``generate_reply_events``
    exist with their call shapes intact, run on ``inference_llm.complete``,
    and consult no routing switch (there is only one route)."""
    for name in ("generate_json", "generate_reply", "generate_reply_events"):
        assert callable(getattr(gemini, name)), name
    for name in ("generate_json", "generate_reply_events"):
        src = ast.unparse(
            next(n for n in ast.parse(_source(ROOT / "gemini.py")).body
                 if getattr(n, "name", "") == name)
        )
        assert "llm_routing.route_for(" not in src, name
        assert "llm_routing.fallback_enabled(" not in src, name
    assert "inference_llm.complete" in _source(ROOT / "gemini.py")


def test_routing_resolves_to_inference_under_every_override(monkeypatch):
    """Hostile flags (all groups pinned to Vertex/Google, fallback on) still
    resolve to Inference with no fallback — the settings are retained but no
    longer honored."""
    import feature_flags

    monkeypatch.setattr(
        feature_flags, "_read_docs", lambda: {
            "llm_route_json": "vertex", "llm_route_vision": "vertex",
            "llm_route_chat": "vertex", "voice_provider": "google",
            "llm_percent_json": 0, "llm_percent_vision": 0,
            "llm_percent_chat": 0, "llm_percent_voice": 0,
            "llm_allowlist_voice": ("someone-else",),
            "llm_fallback_to_google": True,
        }
    )
    feature_flags.reset_cache()
    for group in ("json", "vision", "chat", "voice"):
        assert llm_routing.route_for(group) == "inference"
        assert llm_routing.route_for(group, uid="u1") == "inference"
    assert llm_routing.fallback_enabled() is False
    feature_flags.reset_cache()


def test_branch_defaults_send_every_group_to_inference():
    assert CONFIG.llm_route_json == "inference"
    assert CONFIG.llm_route_vision == "inference"
    assert CONFIG.llm_route_chat == "inference"
    assert CONFIG.voice_provider == "inference"
    assert CONFIG.llm_inference_fallback is False


def _openai_requirement(name: str) -> str:
    lines = [
        line.strip()
        for line in (ROOT / name).read_text(encoding="utf-8").splitlines()
        if line.strip().startswith("openai")
    ]
    assert len(lines) == 1, f"{name} must declare exactly one openai requirement"
    return lines[0]


def test_api_image_pins_the_gateway_client():
    assert _openai_requirement("requirements.txt").startswith("openai==")


def test_worker_images_use_the_gateway_client_range_livekit_agents_needs():
    # livekit-agents 1.8.9 requires openai>=3.19 (an exact 2.x pin fails the image build).
    assert _openai_requirement("requirements-agent.txt") == "openai>=3.19,<4"
