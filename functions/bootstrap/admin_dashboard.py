"""Static HTML for the ``/admin`` provider-spend dashboard (ARCHITECTURE.md §14.3).

The markup lives in ``templates/admin_dashboard.html`` (next to
``referral_page.html``), loaded here as ``DASHBOARD_HTML`` — plain
HTML/CSS/vanilla JS, no build step, no external framework. This is a
one-person internal ops tool (the founder), so legibility beats polish. The
page itself is served with no auth (it's inert without a valid password); the
data it calls (``/admin/provider-spend``, ``/admin/users``) stays behind the
exact same ``require_admin_password`` gate as every other ``/admin/*`` route.

The admin password is:
  - never embedded in this HTML/JS source,
  - never put in a URL query param,
  - never logged (client or server side),
  - kept only in this browser tab's ``sessionStorage`` once typed in, sent
    solely as the ``X-Admin-Password`` header on same-origin fetch() calls.
"""

from __future__ import annotations

from pathlib import Path

_TEMPLATE = Path(__file__).parent / "templates" / "admin_dashboard.html"

DASHBOARD_HTML = _TEMPLATE.read_text(encoding="utf-8")
