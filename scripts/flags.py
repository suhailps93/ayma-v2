#!/usr/bin/env python3
"""List and set Ayma feature flags (Firestore ``config/feature_flags``).

    python3 scripts/flags.py list
    python3 scripts/flags.py set maps_grounding=false llm_route_chat=vertex
    python3 scripts/flags.py rollback            # undo the last `set`/`load`
    python3 scripts/flags.py load scripts/feature_flags.seed.json
    python3 scripts/flags.py history

Every write needs ``--yes`` (otherwise it prints what it would do). Each write
appends the previous flag values to the doc's ``_history`` (last 20), and
``rollback`` restores the most recent entry in one command. ``sentry`` and
``dev_panel`` are also mirrored to ``app_config/<flag>.enabled``, the docs the
mobile client reads. Credentials: your gcloud / ADC identity; nothing is stored here.
Docs: docs/FEATURE_FLAGS.md.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "functions" / "bootstrap"))

import feature_flags as ff  # noqa: E402

HISTORY_KEY = ff.HISTORY_KEY


def _ref(db):
    return db.collection(ff.CONFIG_COLLECTION).document(ff.FLAGS_DOC)


def _flags_of(doc: dict) -> dict:
    return {k: v for k, v in doc.items() if not k.startswith("_")}


def parse_assignments(pairs: list[str]) -> dict:
    out = {}
    for pair in pairs:
        name, sep, text = pair.partition("=")
        if not sep or name not in ff.REGISTRY:
            raise SystemExit(f"unknown flag or bad assignment: {pair!r}")
        try:
            value = ff._parse_env(ff.REGISTRY[name], text)
        except ValueError as exc:
            raise SystemExit(str(exc))
        out[name] = list(value) if isinstance(value, tuple) else value
    return out


def validate_values(values: dict) -> dict:
    out = {}
    for name, raw in values.items():
        if name.startswith("_"):
            continue
        if name not in ff.REGISTRY:
            raise SystemExit(f"unknown flag {name!r}")
        try:
            value = ff._coerce(ff.REGISTRY[name], raw)
        except ValueError as exc:
            raise SystemExit(str(exc))
        out[name] = list(value) if isinstance(value, tuple) else value
    return out


def apply(db, changes: dict, *, by: str) -> dict:
    """Merge ``changes`` into the doc and record the previous values."""
    return ff.write(db, changes, by=by)


def rollback(db) -> dict | None:
    """Restore the flag values from before the most recent write."""
    ref = _ref(db)
    snap = ref.get()
    current = (snap.to_dict() or {}) if snap.exists else {}
    history = list(current.get(HISTORY_KEY) or [])
    if not history:
        return None
    last = history.pop()
    restored = {**last["before"], HISTORY_KEY: history}
    ref.set(restored)
    ff.mirror_to_app(db, last["before"])
    return restored


def _client():
    from db import get_db

    return get_db()


def _who() -> str:
    import getpass

    return getpass.getuser()


def cmd_list(db) -> None:
    doc = (_ref(db).get().to_dict() or {}) if db else {}
    ff.reset_cache()
    ff._cache.update(at=10**12, data=_flags_of(doc))
    print(f"{'flag':30} {'value':28} source")
    for name, info in ff.snapshot().items():
        print(f"{name:30} {str(info['value']):28} {info['source']}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--yes", action="store_true", help="actually write")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", parents=[common])
    sub.add_parser("history", parents=[common])
    sub.add_parser("rollback", parents=[common])
    s = sub.add_parser("set", parents=[common])
    s.add_argument("assignments", nargs="+", metavar="flag=value")
    ld = sub.add_parser("load", parents=[common])
    ld.add_argument("file")
    args = ap.parse_args(argv)

    db = _client()
    if args.cmd == "list":
        cmd_list(db)
        return 0
    if args.cmd == "history":
        for h in (_ref(db).get().to_dict() or {}).get(HISTORY_KEY, []):
            print(h["at"], h["by"], ",".join(h["changed"]))
        return 0
    if args.cmd == "rollback":
        if not args.yes:
            print("would restore the values from before the last write (add --yes)")
            return 0
        restored = rollback(db)
        print("nothing to roll back" if restored is None else "rolled back")
        return 0
    if args.cmd == "set":
        changes = parse_assignments(args.assignments)
    else:
        changes = validate_values(json.loads(Path(args.file).read_text()))
    print("changes:", json.dumps(changes))
    if not args.yes:
        print("dry run (add --yes to write)")
        return 0
    apply(db, changes, by=_who())
    print("written; `rollback --yes` undoes it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
