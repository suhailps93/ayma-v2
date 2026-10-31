#!/usr/bin/env python3
"""End-to-end demo / smoke test of the Ayma MCP server.

Runs the OAuth 2.1 Device Authorization Grant against a running Ayma API, then
connects as an MCP client (the official `mcp` SDK — i.e. exactly what Claude
does) and calls the exposed tools. Nothing here uses any Ayma LLM; the "brain"
is this script, the server is only hands + memory.

Usage
-----
Against a locally-running API (uvicorn main:app --port 8080), with the MCP
feature flag ON (FLAG_MCP_SERVER=1):

    # Approve automatically with a test user's Firebase ID token:
    python3 scripts/mcp_demo.py --base-url http://localhost:8080 \
        --id-token "<firebase-id-token-for-the-test-user>"

    # Or approve by hand in the Ayma app (the script prints the code and waits):
    python3 scripts/mcp_demo.py --base-url https://<your-api-host>

Options:
    --send-to <other_uid> --text "..."   also exercise send_message
    --scope "profile:read matches:read"  request a narrower scope

Requires: `pip install mcp httpx` (both already in requirements.txt).
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import time

import httpx

DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"


async def _device_flow(base: str, client_id: str, scope: str, id_token: str | None) -> str:
    oauth = f"{base}/mcp/oauth"
    async with httpx.AsyncClient(timeout=30) as http:
        r = await http.post(
            f"{oauth}/device_authorization",
            data={"client_id": client_id, "scope": scope},
        )
        r.raise_for_status()
        da = r.json()
        user_code = da["user_code"]
        device_code = da["device_code"]
        interval = int(da.get("interval", 5))
        print(f"\n  Device code issued. user_code = {user_code}")
        print(f"  Approve at: {da.get('verification_uri')}\n")

        if id_token:
            print("  Auto-approving with the supplied Firebase ID token…")
            ar = await http.post(
                f"{base}/mcp/connect/approve",
                headers={"Authorization": f"Bearer {id_token}"},
                json={"user_code": user_code},
            )
            if ar.status_code != 200:
                raise SystemExit(f"approve failed: {ar.status_code} {ar.text}")
            print("  Approved.\n")
        else:
            print("  Open the Ayma app -> Profile -> Connect an agent, enter the")
            print("  code above, and approve. Waiting…\n")

        deadline = time.time() + int(da.get("expires_in", 600))
        while time.time() < deadline:
            tr = await http.post(
                f"{oauth}/token",
                data={
                    "grant_type": DEVICE_GRANT,
                    "device_code": device_code,
                    "client_id": client_id,
                },
            )
            body = tr.json()
            if tr.status_code == 200:
                print("  Access token received.\n")
                return body["access_token"]
            err = body.get("error")
            if err in ("authorization_pending", "slow_down"):
                await asyncio.sleep(interval)
                continue
            raise SystemExit(f"token error: {err} — {body.get('error_description')}")
        raise SystemExit("timed out waiting for approval")


async def _exercise_tools(base: str, token: str, send_to: str | None, text: str | None) -> None:
    from mcp.client.session import ClientSession
    from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

    url = f"{base}/mcp"
    http_client = create_mcp_http_client(headers={"Authorization": f"Bearer {token}"})
    async with streamable_http_client(url, http_client=http_client) as streams:
        read, write = streams[0], streams[1]
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            print("  Tools exposed:")
            for t in tools.tools:
                print(f"    - {t.name}")
            print()

            for name, args in (("get_profile", {}), ("list_matches", {}), ("list_threads", {})):
                print(f"  -> {name}({args})")
                res = await session.call_tool(name, args)
                _print_result(res)

            if send_to and text:
                print(f"  -> send_message(other_uid={send_to!r}, text=…)")
                res = await session.call_tool(
                    "send_message", {"other_uid": send_to, "text": text}
                )
                _print_result(res)


def _print_result(res) -> None:
    if getattr(res, "isError", False):
        print(f"     (refused) {_text(res)}")
    else:
        out = getattr(res, "structuredContent", None) or _text(res)
        print(f"     {out}")
    print()


def _text(res) -> str:
    parts = []
    for c in getattr(res, "content", []) or []:
        parts.append(getattr(c, "text", "") or "")
    return " ".join(p for p in parts if p).strip()


async def _main() -> None:
    ap = argparse.ArgumentParser(description="Ayma MCP server demo / smoke test")
    ap.add_argument("--base-url", default="http://localhost:8080")
    ap.add_argument("--client-id", default="ayma-mcp-demo")
    ap.add_argument(
        "--scope",
        default="profile:read profile:write matches:read dm:read dm:send persona:read",
    )
    ap.add_argument("--id-token", default=None, help="Firebase ID token to auto-approve")
    ap.add_argument("--send-to", default=None, help="other_uid to test send_message")
    ap.add_argument("--text", default=None, help="message text for --send-to")
    args = ap.parse_args()

    base = args.base_url.rstrip("/")
    print("== Ayma MCP demo ==")
    token = await _device_flow(base, args.client_id, args.scope, args.id_token)
    await _exercise_tools(base, token, args.send_to, args.text)
    print("Done.")


if __name__ == "__main__":
    try:
        asyncio.run(_main())
    except KeyboardInterrupt:
        sys.exit(130)
