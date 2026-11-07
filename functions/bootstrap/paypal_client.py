"""PayPal sandbox Orders API client (PayPal AI Hackathon, plan-a-date).

Real integration, sandbox only. When PAYPAL_CLIENT_ID and
PAYPAL_CLIENT_SECRET are set in the environment, orders are created and
captured against the PayPal sandbox REST API
(https://api-m.sandbox.paypal.com). When they are not set, the stub client
below is used instead: it mints clearly-labelled test order ids and
captures them locally, so the in-app flow can be run and tested end to
end with no credentials. A stub order is always marked ``stubbed: True``
and is never presented as a real PayPal order.

One PayPal order has one payer, so a split date is two linked
half-amount orders — see date_plan.create_split_orders.
"""

from __future__ import annotations

import base64
import json
import os
import urllib.request

SANDBOX_API_BASE = "https://api-m.sandbox.paypal.com"


def _dollars(cents: int) -> str:
    return f"{cents / 100:.2f}"


class PayPalError(RuntimeError):
    pass


class PayPalSandboxClient:
    """Talks to the real PayPal sandbox Orders API over HTTPS."""

    def __init__(self, client_id: str, client_secret: str,
                 api_base: str = SANDBOX_API_BASE) -> None:
        self._client_id = client_id
        self._client_secret = client_secret
        self._api_base = api_base.rstrip("/")
        self.stubbed = False

    def _access_token(self) -> str:
        raw = f"{self._client_id}:{self._client_secret}".encode()
        req = urllib.request.Request(
            f"{self._api_base}/v1/oauth2/token",
            data=b"grant_type=client_credentials",
            headers={
                "Authorization": "Basic " + base64.b64encode(raw).decode(),
                "Content-Type": "application/x-www-form-urlencoded",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.loads(resp.read().decode())
        except Exception as exc:  # noqa: BLE001 - surface as one error type
            raise PayPalError(f"PayPal sandbox sign-in failed: {exc}") from exc
        token = str(body.get("access_token", ""))
        if not token:
            raise PayPalError("PayPal sandbox sign-in returned no token.")
        return token

    def _call(self, method: str, path: str, payload: dict | None) -> dict:
        token = self._access_token()
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(
            f"{self._api_base}{path}",
            data=data,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                text = resp.read().decode()
        except Exception as exc:  # noqa: BLE001
            raise PayPalError(f"PayPal sandbox call {path} failed: {exc}") from exc
        return json.loads(text) if text else {}

    def create_order(self, amount_cents: int, currency: str,
                     reference_id: str, return_url: str = "",
                     cancel_url: str = "") -> dict:
        payload: dict[str, object] = {
            "intent": "CAPTURE",
            "purchase_units": [{
                "reference_id": reference_id,
                "description": "Ayma date plan - your half",
                "amount": {
                    "currency_code": currency,
                    "value": _dollars(amount_cents),
                },
            }],
        }
        if return_url:
            payload["application_context"] = {
                "return_url": return_url,
                "cancel_url": cancel_url or return_url,
            }
        body = self._call("POST", "/v2/checkout/orders", payload)
        order_id = str(body.get("id", ""))
        if not order_id:
            raise PayPalError("PayPal sandbox did not return an order id.")
        approve_url = ""
        for link in body.get("links", []) or []:
            if isinstance(link, dict) and link.get("rel") == "approve":
                approve_url = str(link.get("href", ""))
        return {
            "order_id": order_id,
            "approve_url": approve_url,
            "status": str(body.get("status", "CREATED")),
            "stubbed": False,
        }

    def capture_order(self, order_id: str) -> dict:
        body = self._call(
            "POST", f"/v2/checkout/orders/{order_id}/capture", {})
        status = str(body.get("status", ""))
        if status != "COMPLETED":
            raise PayPalError(
                f"PayPal sandbox capture ended as {status or 'unknown'}, "
                "not COMPLETED. The payer may not have approved yet.")
        capture_id = ""
        try:
            units = body["purchase_units"]
            capture_id = str(
                units[0]["payments"]["captures"][0]["id"])
        except Exception:  # noqa: BLE001 - id is nice to have, not vital
            capture_id = ""
        return {"capture_id": capture_id, "status": status, "stubbed": False}


class StubPayPalClient:
    """No-credentials stand-in. Clearly labelled, sandbox-shaped ids."""

    stubbed = True

    def create_order(self, amount_cents: int, currency: str,
                     reference_id: str, return_url: str = "",
                     cancel_url: str = "") -> dict:
        order_id = "STUB-" + reference_id.upper().replace("_", "-")
        return {
            "order_id": order_id,
            "approve_url": (
                "https://www.sandbox.paypal.com/checkoutnow?token="
                + order_id),
            "status": "CREATED",
            "stubbed": True,
        }

    def capture_order(self, order_id: str) -> dict:
        return {
            "capture_id": "STUB-CAPTURE-" + order_id,
            "status": "COMPLETED",
            "stubbed": True,
        }


def get_client() -> PayPalSandboxClient | StubPayPalClient:
    """The real sandbox client when credentials are configured, else stub."""
    client_id = os.environ.get("PAYPAL_CLIENT_ID", "").strip()
    client_secret = os.environ.get("PAYPAL_CLIENT_SECRET", "").strip()
    if client_id and client_secret:
        return PayPalSandboxClient(
            client_id, client_secret,
            os.environ.get("PAYPAL_API_BASE", SANDBOX_API_BASE))
    return StubPayPalClient()
