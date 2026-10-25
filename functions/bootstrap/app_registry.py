"""The app-control registry: every page Ayma can open and every setting she can
change, loaded from ``app_registry.json`` (the single source of truth).

``skills/app_control.py`` builds its tool descriptions and validation from
this; the Flutter client navigates to the ``path`` each command carries, and
two tests (``tests/test_app_registry.py`` here, ``test/app_registry_test.dart``
in the app) fail when a GoRoute in ``app_router.dart`` is neither registered
nor listed as non-navigable with a reason.

Lookups accept the user's own words: a key, a label, or any alias, matched
after :func:`normalise` (lowercase, punctuation and filler words such as
"my", "the", "page", "screen", "card" removed).
"""

from __future__ import annotations

import functools
import json
import re
from pathlib import Path

_PATH = Path(__file__).with_name("app_registry.json")

# Words that carry no meaning in "open my profile completeness card please".
_FILLER = frozenset(
    "a an the my me your our to of for please open show go take "
    "page pages screen screens tab card section view".split()
)


@functools.lru_cache(maxsize=1)
def registry() -> dict:
    return json.loads(_PATH.read_text(encoding="utf-8"))


def destinations() -> list[dict]:
    return list(registry()["destinations"])


def settings() -> list[dict]:
    return list(registry()["settings"])


def account_actions() -> list[dict]:
    return list(registry()["account_actions"])


def unavailable() -> list[dict]:
    return list(registry()["unavailable"])


def normalise(text: str) -> str:
    """Lowercase words with filler and numbers dropped, so the card's own
    text ("Your profile is 59% complete") matches its alias."""
    words = re.sub(r"[^a-z0-9]+", " ", text.lower().replace("'", "")).split()
    return " ".join(w for w in words if w not in _FILLER and not w.isdigit())


def _names(entry: dict) -> list[str]:
    names = [entry["key"], entry["key"].replace("_", " ")]
    if entry.get("label"):
        names.append(entry["label"])
    names.extend(entry.get("aliases") or [])
    return [n for n in (normalise(x) for x in names) if n]


def _lookup(entries: list[dict], text: str, exact: bool = False) -> dict | None:
    """Exact key/label/alias match first; otherwise (unless ``exact``) the
    entry whose longest name is contained in the request (or contains it), so
    "open the profile completeness card" finds ``complete_profile``. ``None``
    when nothing fits."""
    want = normalise(text)
    if not want:
        return None
    raw = text.strip().lower()
    for e in entries:
        if raw == e["key"] or want in _names(e):
            return e
    if exact:
        return None
    best: tuple[int, dict] | None = None
    for e in entries:
        for n in _names(e):
            if len(n) < 4:
                continue
            if re.search(rf"\b{re.escape(n)}\b", want) or (
                len(want) >= 6 and re.search(rf"\b{re.escape(want)}\b", n)
            ):
                if best is None or len(n) > best[0]:
                    best = (len(n), e)
    return best[1] if best else None


def find_destination(text: str) -> dict | None:
    """An exact destination name wins; then an exact known-unavailable name
    ("google account") blocks a looser destination match ("account")."""
    exact = _lookup(destinations(), text, exact=True)
    if exact or find_unavailable(text, exact=True):
        return exact
    return _lookup(destinations(), text)


def find_setting(text: str) -> dict | None:
    return _lookup(settings(), text)


def find_account_action(text: str) -> dict | None:
    return _lookup(account_actions(), text)


def find_unavailable(text: str, exact: bool = False) -> dict | None:
    return _lookup(unavailable(), text, exact)


def found_on(screen_key: str) -> list[str]:
    """Labels of everything that sits on one screen, for screen context."""
    out = []
    for group in (destinations(), settings(), account_actions()):
        for e in group:
            if e.get("found_on") == screen_key:
                out.append(e.get("on_screen") or e["label"])
    return out
