#!/usr/bin/env python3
"""Purge the retired ``wiki_pages`` store from STAGING Firestore.

Phase 7 of the person-graph switch: with ``PERSON_GRAPH_READS`` on, staging code
neither reads nor writes ``wiki_pages`` (every reader is gated flag-on → the
graph; every writer is gated or disabled). The old store is dead and is deleted
here. This script is used two ways:

* the one-time Phase 7 deletion, and
* a **post-import purge step** in ``sync-prod-to-staging.sh`` — the nightly
  prod→staging Firestore import re-copies prod's live ``wiki_pages`` into
  staging (managed import ``--collection-ids`` is include-only, so it cannot be
  excluded at import time), so staging purges it again right after each import.

It deletes every ``wiki_pages`` document found by a collection-group query —
covering both ``users/{uid}/wiki_pages`` and ``deleted_accounts/{uid}/
wiki_pages`` — **recursively**, so each page's ``versions`` subcollection
(story_versions, up to 50/section) goes with it and is never orphaned.

STAGING ONLY. A hard guard refuses to run against prod (``ayma-ai``) or any
project other than the expected staging project.

Usage:
    purge_staging_wiki_pages.py                 # DRY-RUN (default; counts only)
    purge_staging_wiki_pages.py --dry-run       # explicit dry-run
    purge_staging_wiki_pages.py --execute       # perform the recursive delete
    purge_staging_wiki_pages.py --project ayma-staging --execute
"""
from __future__ import annotations

import argparse
import sys

from google.cloud import firestore

STAGING_PROJECT = "ayma-staging"


def _guard(project: str) -> None:
    """Refuse to touch prod or any non-staging project."""
    if "ayma-ai" in project:
        sys.exit(f"GUARDRAIL TRIPPED — refusing to purge PROD project {project!r}. STAGING ONLY.")
    if project != STAGING_PROJECT:
        sys.exit(
            f"GUARDRAIL — project {project!r} is not the expected staging project "
            f"{STAGING_PROJECT!r}. Pass --project {STAGING_PROJECT} to proceed."
        )


def _count(db: firestore.Client) -> tuple[int, int]:
    pages = sum(1 for _ in db.collection_group("wiki_pages").stream())
    versions = sum(1 for _ in db.collection_group("versions").stream())
    return pages, versions


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Purge staging wiki_pages (recursive).")
    ap.add_argument("--project", default=STAGING_PROJECT)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--execute", action="store_true", help="perform the delete")
    mode.add_argument("--dry-run", action="store_true", help="count only (default)")
    args = ap.parse_args(argv)

    _guard(args.project)
    db = firestore.Client(project=args.project)

    pages_before, versions_before = _count(db)
    print(f"[purge] project={args.project} wiki_pages={pages_before} versions={versions_before}")

    if not args.execute:
        print("[purge] DRY-RUN — no writes. Re-run with --execute to delete.")
        return 0

    deleted = 0
    for page in db.collection_group("wiki_pages").stream():
        # recursive_delete removes the page doc AND its versions subcollection.
        db.recursive_delete(page.reference)
        deleted += 1

    pages_after, versions_after = _count(db)
    print(f"[purge] deleted {deleted} wiki_pages docs (recursive, incl. versions)")
    print(f"[purge] remaining wiki_pages={pages_after} versions={versions_after}")
    if pages_after or versions_after:
        sys.exit(f"[purge] FAILED — {pages_after} wiki_pages / {versions_after} versions still remain.")
    print("[purge] OK — staging wiki_pages fully removed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
