"""Make the extracted backend importable in isolation.

Adds the backend dir (real hackathon-new modules) and the ``_stubs`` dir
(clearly-labelled stand-ins for Ayma's private core — see ``_stubs/README.md``)
to ``sys.path``. The backend dir is inserted FIRST so a real deliverable module
(e.g. ``config.py``) always wins over anything in ``_stubs``; the stubs only
resolve the private-core imports that have no public module.

Tests must run isolated from any real credentials, so ``META_API_KEY`` is
cleared for the whole session (no test makes a live Meta call).
"""

import os
import sys
from pathlib import Path

_BACKEND = Path(__file__).resolve().parent.parent
_STUBS = _BACKEND / "_stubs"

for p in (str(_BACKEND), str(_STUBS)):
    if p not in sys.path:
        sys.path.insert(0, p)
# Backend must take precedence over _stubs for shared names.
sys.path.remove(str(_BACKEND))
sys.path.insert(0, str(_BACKEND))

os.environ.pop("META_API_KEY", None)
