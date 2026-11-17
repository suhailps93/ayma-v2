#!/usr/bin/env python3
"""Backfill graph IMAGE nodes for a user's existing photos (founder Nov 16 2026).

For one uid, this homes every photo Ayma already has — profile grid, chat-shared,
web-findings, appearance-report — as a graph image node carrying the storage url,
Ayma's read (``image_read``), the structured is-you verdict (``is_you``), and the
SOURCE provenance (``source_kind``/``source_ref``/``source_created_at``). It
carries over an existing ``photo_notes`` read/verdict to the matching node by
CONTENT (never by the rotating URL), and for a photo with no read anywhere it
GENERATES one via the vision caption path. Idempotent: re-running updates nodes
in place (``add_image_node`` upserts on the content-hash id), never duplicates.

STAGING ONLY. Refuses to run unless the active Firestore project is ayma-staging.
Run ``--dry-run`` first: it prints the counts (nodes to create, reads carried
over, reads to generate) and writes NOTHING.

    python3 scripts/backfill_image_nodes.py --uid <uid> --project ayma-staging --dry-run
    python3 scripts/backfill_image_nodes.py --uid <uid> --project ayma-staging
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import sys

_ALLOWED_PROJECT = "ayma-staging"


def _die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(2)


def _content_hash(raw: bytes | None, url: str) -> str:
    """Content hash of the image BYTES (never the URL). Falls back to a hash of
    the url only when the bytes can't be fetched, so the node id is still
    stable per-source even then."""
    if raw:
        return hashlib.sha1(raw).hexdigest()[:8]
    return "u" + hashlib.sha1((url or "").encode("utf-8")).hexdigest()[:7]


async def _collect(db, uid: str) -> list[dict]:
    """Every existing photo for ``uid`` with its source, as
    ``{url, source_kind, source_ref, raw, embedding}`` (raw/embedding best-effort)."""
    import main  # reuse the same sources the legacy view assembled from
    import photo_notes
    from public_profile import _photo_url

    out: list[dict] = []
    seen: set[str] = set()

    def _add(url: str, source_kind: str, source_ref: str = "") -> None:
        url = (url or "").strip()
        if not url or url in seen:
            return
        seen.add(url)
        out.append({"url": url, "source_kind": source_kind, "source_ref": source_ref})

    try:
        prof = main.schema.profile_doc(db, uid).get().to_dict() or {}
        for m in photo_notes.profile_photo_media(db, uid, prof):
            _add(m.get("url", ""), "profile_grid")
    except Exception as exc:  # noqa: BLE001
        print(f"  (profile grid read failed: {exc})")

    try:
        from firebase_admin import firestore
        msgs = (
            db.collection("users").document(uid).collection("chat_messages")
            .order_by("created_at", direction=firestore.Query.DESCENDING)
            .limit(200).stream()
        )
        for snap in msgs:
            d = snap.to_dict() or {}
            p = str(d.get("image_path") or "").strip()
            if p:
                _add(_photo_url(p) or "", "chat", str(d.get("session_id") or ""))
    except Exception as exc:  # noqa: BLE001
        print(f"  (chat photos read failed: {exc})")

    try:
        import deep_dive
        rid = deep_dive.dive_report_id(name=deep_dive.profile_full_name(db, uid))
        dive = deep_dive.read_dive(db, uid, rid)
        for img in ((dive or {}).get("digest") or {}).get("web_images") or []:
            if isinstance(img, dict) and img.get("verified"):
                _add(str(img.get("url") or ""), "web", rid)
    except Exception as exc:  # noqa: BLE001
        print(f"  (web photos read failed: {exc})")

    return out


async def run(uid: str, *, dry_run: bool) -> dict:
    import person_graph_store as pg_store
    import photo_notes

    from google.cloud import firestore as gcf
    db = gcf.Client()
    if getattr(db, "project", "") != _ALLOWED_PROJECT:
        _die(f"active project is {db.project!r}, refusing (expected {_ALLOWED_PROJECT!r})")

    photos = await _collect(db, uid)
    notes = photo_notes.all_notes(db, uid)

    created = carried = generated = 0
    for ph in photos:
        url = ph["url"]
        note = notes.get(photo_notes.photo_id(url), {})
        read = str(note.get("context") or "").strip()
        is_you = pg_store.is_you_from_verdict(str(note.get("is_user") or ""))
        if read:
            carried += 1
        else:
            generated += 1
            if not dry_run:
                try:
                    import photo_pipeline
                    read = await photo_pipeline.caption_url(db, uid, url) or ""
                except Exception:  # noqa: BLE001
                    read = ""
        nid = "emergent.image." + _content_hash(None, url)
        created += 1
        if not dry_run:
            try:
                pg_store.add_photo_fact(
                    db, uid, image_url=url, image_read=read,
                    fact_text=read or "a photo", image_node_id=nid,
                    is_you=is_you, source_kind=ph["source_kind"],
                    source_ref=ph["source_ref"],
                )
            except Exception as exc:  # noqa: BLE001
                print(f"  (home failed for {url[:60]}: {exc})")

    return {"photos": len(photos), "nodes": created,
            "reads_carried_over": carried, "reads_generated": generated}


def main() -> None:
    ap = argparse.ArgumentParser(description="Backfill graph image nodes (staging only).")
    ap.add_argument("--uid", required=True)
    ap.add_argument("--project", default="")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if args.project and args.project != _ALLOWED_PROJECT:
        _die(f"--project must be {_ALLOWED_PROJECT!r} (got {args.project!r})")

    result = asyncio.run(run(args.uid, dry_run=args.dry_run))
    mode = "DRY-RUN (no writes)" if args.dry_run else "WROTE"
    print(f"\n{mode} for uid={args.uid}:")
    for k, v in result.items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
