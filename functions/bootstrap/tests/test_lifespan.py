"""main.app lifespan wiring (replaces deprecated @app.on_event): startup
enters the MCP session manager + Gemini warmup, shutdown closes the stack."""

import asyncio
import contextlib

import main


def test_no_deprecated_on_event_handlers():
    assert main.app.router.on_startup == []
    assert main.app.router.on_shutdown == []
    assert main.app.router.lifespan_context is not None


def test_lifespan_runs_startup_then_shutdown(monkeypatch):
    calls = []

    @contextlib.asynccontextmanager
    async def fake_mcp_lifespan():
        calls.append("mcp-enter")
        yield
        calls.append("mcp-exit")

    async def fake_warmup():
        calls.append("warmup")

    monkeypatch.setattr(main.mcp_server, "lifespan", fake_mcp_lifespan)
    monkeypatch.setattr(main.gemini, "warmup", fake_warmup)

    async def _run():
        async with main.app.router.lifespan_context(main.app):
            assert calls == ["mcp-enter", "warmup"]

    asyncio.run(_run())
    assert calls == ["mcp-enter", "warmup", "mcp-exit"]
