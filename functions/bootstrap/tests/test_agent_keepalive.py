"""Per-call keep-alive (agent_keepalive): server holds, instance pinning,
client retry and release. Real aiohttp on localhost; the ID token and the
metadata-server instance id are faked."""

import asyncio
import dataclasses
import logging

import pytest

aiohttp = pytest.importorskip("aiohttp")
from aiohttp import web  # noqa: E402

import agent_keepalive  # noqa: E402
from agent_keepalive import CallKeepAlive, KeepAliveServer  # noqa: E402


def _instance(value):
    async def fn(*_args):
        return value

    return fn


async def _start(server):
    await server.start()
    return server._runner.addresses[0][1]


async def _wait_for(predicate, timeout=3.0):
    deadline = asyncio.get_running_loop().time() + timeout
    while not predicate():
        if asyncio.get_running_loop().time() > deadline:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(0.01)


def _client(port, instance="inst-a", **kw):
    return CallKeepAlive(
        "job-1",
        service_url=f"http://127.0.0.1:{port}/",
        enabled=True,
        token_fn=lambda _aud: "tok",
        instance_id_fn=_instance(instance),
        retry_step_seconds=0.01,
        retry_max_seconds=0.02,
        **kw,
    )


def test_server_health_and_wrong_instance_is_rejected():
    async def run():
        server = KeepAliveServer(
            "127.0.0.1", 0, instance_id=_instance("inst-a")
        )
        port = await _start(server)
        try:
            async with aiohttp.ClientSession() as http:
                async with http.get(f"http://127.0.0.1:{port}/") as resp:
                    assert resp.status == 200
                async with http.get(
                    f"http://127.0.0.1:{port}/keepalive",
                    params={"job": "j", "instance": "inst-b"},
                ) as resp:
                    assert resp.status == 409
            assert server.active_holds == 0
        finally:
            await server.aclose()

    asyncio.run(run())


def test_server_streams_heartbeats_until_caller_leaves(caplog):
    caplog.set_level(logging.INFO, logger="ayma.agent_keepalive")

    async def run():
        server = KeepAliveServer(
            "127.0.0.1", 0, instance_id=_instance("inst-a"),
            heartbeat_seconds=0.02,
        )
        port = await _start(server)
        try:
            async with aiohttp.ClientSession() as http:
                async with http.get(
                    f"http://127.0.0.1:{port}/keepalive",
                    params={"job": "j1", "instance": "inst-a"},
                ) as resp:
                    assert resp.status == 200
                    assert await resp.content.readline() == b".\n"
                    assert await resp.content.readline() == b".\n"
                    assert server.active_holds == 1
            await _wait_for(lambda: server.active_holds == 0)
        finally:
            await server.aclose()

    asyncio.run(run())
    assert "keepalive hold start job=j1 active_holds=1" in caplog.text
    assert "keepalive hold end job=j1 reason=caller_closed" in caplog.text


def test_server_ends_hold_after_max_duration():
    async def run():
        server = KeepAliveServer(
            "127.0.0.1", 0, instance_id=_instance("inst-a"),
            heartbeat_seconds=0.01, max_hold_seconds=0.05,
        )
        port = await _start(server)
        try:
            async with aiohttp.ClientSession() as http:
                async with http.get(
                    f"http://127.0.0.1:{port}/keepalive",
                    params={"instance": "inst-a"},
                ) as resp:
                    body = await asyncio.wait_for(resp.read(), 2)
            assert body.startswith(b".\n")
            assert server.active_holds == 0
        finally:
            await server.aclose()

    asyncio.run(run())


def test_client_holds_for_the_call_and_releases_after_held_work(caplog):
    caplog.set_level(logging.INFO, logger="ayma.agent_keepalive")

    async def run():
        server = KeepAliveServer(
            "127.0.0.1", 0, instance_id=_instance("inst-a"),
            heartbeat_seconds=0.02,
        )
        port = await _start(server)
        flush_done = asyncio.Event()
        flushed = []

        async def flush():
            await flush_done.wait()
            flushed.append(True)

        try:
            keepalive = _client(port)
            keepalive.start()
            keepalive.hold_for(flush)
            await _wait_for(lambda: server.active_holds == 1)

            release = asyncio.create_task(keepalive.release())
            await asyncio.sleep(0.05)
            # The memory flush is still writing: the hold must stay open.
            assert not release.done()
            assert server.active_holds == 1

            flush_done.set()
            await asyncio.wait_for(release, 2)
            assert flushed == [True]
            await _wait_for(lambda: server.active_holds == 0)
            assert keepalive.holds_opened == 1
        finally:
            await server.aclose()

    asyncio.run(run())
    assert "keepalive held job=job-1 hold=1" in caplog.text
    assert "keepalive released job=job-1" in caplog.text


def test_client_retries_until_it_lands_on_its_own_instance():
    async def run():
        calls = []

        async def handler(request):
            calls.append(request.query["instance"])
            assert request.headers["Authorization"] == "Bearer tok"
            if len(calls) < 3:  # load balancer picked another instance
                return web.Response(status=409)
            resp = web.StreamResponse()
            await resp.prepare(request)
            await resp.write(b".\n")
            await asyncio.sleep(10)
            return resp

        app = web.Application()
        app.add_routes([web.get("/keepalive", handler)])
        runner = web.AppRunner(app)
        await runner.setup()
        await web.TCPSite(runner, "127.0.0.1", 0).start()
        port = runner.addresses[0][1]
        try:
            keepalive = _client(port)
            keepalive.start()
            await _wait_for(lambda: keepalive.holds_opened == 1)
            assert calls == ["inst-a"] * 3
            await keepalive.stop()
        finally:
            await runner.cleanup()

    asyncio.run(run())


def test_client_reopens_when_a_hold_ends_mid_call():
    async def run():
        server = KeepAliveServer(
            "127.0.0.1", 0, instance_id=_instance("inst-a"),
            heartbeat_seconds=0.01, max_hold_seconds=0.03,
        )
        port = await _start(server)
        try:
            keepalive = _client(port)
            keepalive.start()
            await _wait_for(lambda: keepalive.holds_opened >= 2)
            await keepalive.stop()
        finally:
            await server.aclose()

    asyncio.run(run())


def test_client_survives_errors_and_keeps_retrying(caplog):
    attempts = []

    async def failing_instance(_http):
        attempts.append(1)
        raise RuntimeError("metadata server down")

    async def run():
        keepalive = CallKeepAlive(
            "job-1", service_url="http://127.0.0.1:9", enabled=True,
            token_fn=lambda _aud: "tok", instance_id_fn=failing_instance,
            retry_step_seconds=0.001, retry_max_seconds=0.001,
        )
        keepalive.start()
        await _wait_for(lambda: len(attempts) >= agent_keepalive.WARN_AFTER_FAILURES)
        await keepalive.release()

    asyncio.run(run())
    assert "keepalive not held yet job=job-1" in caplog.text


def test_client_is_a_noop_off_cloud_run(monkeypatch):
    monkeypatch.delenv("K_SERVICE", raising=False)
    keepalive = CallKeepAlive.for_job("job-1")

    async def run():
        keepalive.start()
        assert keepalive._task is None
        await keepalive.release()

    asyncio.run(run())


def test_client_enabled_on_cloud_run_with_service_url(monkeypatch):
    monkeypatch.setenv("K_SERVICE", "ayma-agent")
    monkeypatch.setattr(
        agent_keepalive,
        "CONFIG",
        dataclasses.replace(agent_keepalive.CONFIG, agent_url="https://agent.example"),
    )
    assert CallKeepAlive.for_job("job-1")._enabled is True
