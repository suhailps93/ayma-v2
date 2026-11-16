"""Phase 7 — the staging wiki_pages purge must NEVER touch prod.

The purge recursively deletes a whole Firestore collection group, so its project
guard is the one thing standing between a staging cleanup and a prod data-loss
incident. Pin it: the guard exits on prod (``ayma-ai``) and on any non-staging
project, and passes only for ``ayma-staging``.
"""

import importlib.util
import sys
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parents[3] / "scripts" / "purge_staging_wiki_pages.py"


def _load():
    spec = importlib.util.spec_from_file_location("purge_staging_wiki_pages", _SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


purge = _load()


def test_guard_refuses_prod():
    with pytest.raises(SystemExit) as e:
        purge._guard("ayma-ai")
    assert "PROD" in str(e.value)


def test_guard_refuses_arbitrary_project():
    with pytest.raises(SystemExit):
        purge._guard("some-other-project")


def test_guard_allows_staging():
    purge._guard("ayma-staging")  # does not raise
