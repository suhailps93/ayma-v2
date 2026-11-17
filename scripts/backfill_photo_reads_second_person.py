#!/usr/bin/env python3
"""Backfill: rewrite already-stored CONFIRMED-USER photo reads into the second
person (founder rule Nov 17 — a confirmed-user photo's read must say "you", not
"a man / a woman / a person").

New reads are generated second-person at the source (photo_pipeline._caption +
prompts/photo_context_note.md). This fixes the ones ALREADY stored third-person:
- the gallery note shown in the photo view (photo_notes `context`, is_user=="yes")
- the image node's read in the person graph (image_read, is_you=="yes")

The rewrite is an LLM call routed through the normal inference gateway (LiveKit);
it does NOT call any provider directly. So the WRITE path needs the deploy env's
LiveKit credentials — run it from there, not a bare local shell:

  GOOGLE_CLOUD_PROJECT=ayma-staging PYTHONPATH=functions/bootstrap \\
    python3 scripts/backfill_photo_reads_second_person.py --uid <uid> --project ayma-staging [--write]

Dry-run by default (prints what it WOULD rewrite, no model call, no write).
Staging-guarded: refuses to run against a client whose project isn't the one
passed with --project.
"""
from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

_PROMPT = (
    Path(__file__).resolve().parents[1]
    / "functions" / "bootstrap" / "prompts" / "photo_read_second_person_rewrite.md"
)

_REWRITE_SCHEMA = {
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"],
}


def _guard_project(db, expected: str) -> None:
    got = getattr(db, "project", None) or getattr(db, "_project", None)
    if expected and got and got != expected:
        sys.exit(f"REFUSING: client project {got!r} != --project {expected!r}")


async def _rewrite(read: str, *, uid: str) -> str:
    import gemini
    import token_ledger
    from prompt import load_prompt_file

    result = await gemini.generate_json(
        f"Rewrite this photo note into the second person:\n\n{read}",
        system_prompt=load_prompt_file(_PROMPT),
        response_schema=_REWRITE_SCHEMA,
        uid=uid,
        feature=token_ledger.FEATURE_PHOTO_CAPTION,
        enforce_cap=False,
    )
    out = (result or {}).get("text", "").strip() if isinstance(result, dict) else ""
    return out or read


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--uid", required=True)
    ap.add_argument("--project", default="ayma-staging")
    ap.add_argument("--write", action="store_true", help="apply (default: dry-run)")
    args = ap.parse_args()

    import photo_notes
    import person_graph_store as pg_store
    from google.cloud import firestore as gcf

    db = gcf.Client()
    _guard_project(db, args.project)

    # 1) gallery notes (the photo-view "What Ayma knows") for confirmed-user photos
    notes = photo_notes.all_notes(db, args.uid)
    confirmed_notes = {
        pid: d for pid, d in notes.items()
        if str(d.get("is_user")) == "yes" and str(d.get("context") or "").strip()
    }
    # 2) image nodes (person graph) confirmed as the user
    img_nodes = [
        n for n in pg_store.image_nodes_for_view(db, args.uid)
        if str(n.get("is_you")) == "yes" and str(n.get("read") or "").strip()
    ]

    print(f"uid={args.uid} project={args.project} write={args.write}")
    print(f"confirmed gallery notes: {len(confirmed_notes)} | image nodes: {len(img_nodes)}")

    if not args.write:
        for pid, d in confirmed_notes.items():
            print(f"  [note {pid}] {d.get('context')[:80]!r} -> (would rewrite 2nd-person)")
        for n in img_nodes:
            print(f"  [node {n.get('id')}] {str(n.get('read'))[:80]!r} -> (would rewrite)")
        print("DRY-RUN: no model calls, no writes. Re-run with --write from the deploy env.")
        return

    for pid, d in confirmed_notes.items():
        new = await _rewrite(str(d["context"]), uid=args.uid)
        if new != d["context"]:
            photo_notes.set_context(db, args.uid, str(d.get("url") or pid), context=new)
            print(f"  note {pid}: rewritten")
    for n in img_nodes:
        new = await _rewrite(str(n["read"]), uid=args.uid)
        if new != n["read"]:
            pg_store.set_image_read(db, args.uid, str(n["id"]), new)
            print(f"  node {n.get('id')}: rewritten")
    print("DONE.")


if __name__ == "__main__":
    asyncio.run(main())
