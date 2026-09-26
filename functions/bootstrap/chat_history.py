"""The user-visible Ayma-tab transcript.

Two sources, merged by :func:`recent`:

* ``users/{uid}/chat_messages/{id}`` — one doc per **text** message, written by
  ``POST /chat``. Carries a per-message ``created_at`` and any
  ``uploads/{uid}/…`` ``image_path`` (the client resolves it to a URL).
* ``users/{uid}/raw_turns/{sessionId}`` — the per-session substrate wiki ingest
  reads: one doc per session holding the full interleaved **voice + text**
  window (``turns: [{role, text}]``). This is where voice conversations,
  Ayma's re-engagement check-ins, and any text that predates ``chat_messages``
  live.

``recent`` flattens both onto one timeline so the transcript shows everything
the user has actually said to Ayma, not just post-feature text.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from firebase_admin import firestore

_MAX_TEXT = 8000
_MAX_PAGE = 100
_MAX_SESSIONS = 150  # raw_turns docs scanned per history load


def _user(db, uid: str):
    return db.collection("users").document(uid)


import re

# "(shared a photo)", "[shared an image]", "shared a photo" — the placeholder
# text the client / _persist_session attach to an image turn. On reload the
# bubble should show the image, not the placeholder, so we strip it.
_PHOTO_MARKER = re.compile(
    r"[\[(]?\s*shared (?:a|an) (?:photo|image|picture)\s*[\])]?",
    re.IGNORECASE,
)


def _strip_photo_marker(text: str) -> str:
    return _PHOTO_MARKER.sub("", text or "").strip()


def append(
    db,
    uid: str,
    role: str,
    text: str,
    *,
    image_path: str | None = None,
    tools: list[str] | None = None,
    subject_image: str | None = None,
) -> None:
    """Append one message. No-op for an unknown role or an empty text with no
    image. Best-effort — callers wrap it so a write failure never fails /chat.

    ``tools`` are the user-facing labels for what Ayma did on this turn
    ("Searched the web", "Researched Jane Doe online") — persisted so the
    kicker survives a reload. ``subject_image`` is a resolved photo URL for
    the person a skill was run on (Explore deep-dive) so the history row can
    show their face.
    """
    if not uid or role not in ("user", "ayma"):
        return
    text = (text or "").strip()
    if image_path:
        # An image turn stores only real text — never a "shared a photo"
        # placeholder — so the reloaded transcript renders the image itself.
        text = _strip_photo_marker(text)
    if not text and not image_path:
        return
    doc = {
        "role": role,
        "text": text[:_MAX_TEXT],
        "image_path": image_path or "",
        "created_at": firestore.SERVER_TIMESTAMP,
    }
    labels = [str(t).strip() for t in (tools or []) if str(t).strip()]
    if labels:
        doc["tools"] = labels[:6]
    if subject_image:
        doc["subject_image"] = str(subject_image)
    _user(db, uid).collection("chat_messages").add(doc)


def _as_dt(v):
    return v if hasattr(v, "isoformat") else None


def _norm_role(r: str) -> str:
    return "user" if r == "user" else "ayma"


def _collect(db, uid: str) -> list[dict]:
    """Every turn from both sources as ``{ts, role, text, image_path}`` dicts,
    newest-first is *not* guaranteed here — the caller sorts."""
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()

    # chat_messages first — they own the real per-turn timestamp + image path.
    try:
        cm = list(
            _user(db, uid)
            .collection("chat_messages")
            .order_by("created_at", direction=firestore.Query.DESCENDING)
            .limit(_MAX_PAGE * 3)
            .stream()
        )
    except Exception:  # noqa: BLE001
        cm = []
    for doc in cm:
        d = doc.to_dict() or {}
        ts = _as_dt(d.get("created_at"))
        text = str(d.get("text", ""))
        role = _norm_role(str(d.get("role", "ayma")))
        image_path = str(d.get("image_path", ""))
        # de-dup keys against the raw_turns pass: the bare text, and the text
        # with a photo marker (that's how _persist_session records image turns).
        seen.add((role, text.strip()))
        seen.add((role, _strip_photo_marker(text)))
        out.append({
            "ts": ts,
            "role": role,
            "text": text[:_MAX_TEXT],
            "image_path": image_path,
            "tools": [str(t) for t in (d.get("tools") or []) if str(t).strip()],
            "subject_image": str(d.get("subject_image", "")),
        })

    # raw_turns — the interleaved voice+text window per session. One doc holds
    # the whole session; `updated_at` is the session's last write, so give each
    # turn a tiny per-index offset to keep intra-session order stable.
    try:
        rt = list(
            _user(db, uid)
            .collection("raw_turns")
            .order_by("updated_at", direction=firestore.Query.DESCENDING)
            .limit(_MAX_SESSIONS)
            .stream()
        )
    except Exception:  # noqa: BLE001
        rt = []
    for doc in rt:
        # DM ingest reuses persist_raw_turns to give the wiki pipeline a
        # substrate, keyed `dm-{threadId}-{msgId}`. Those are NOT Ayma-chat
        # turns — skip them or a DM you sent shows up in the Ayma transcript.
        if doc.id.startswith("dm-"):
            continue
        d = doc.to_dict() or {}
        base = _as_dt(d.get("updated_at"))
        turns = d.get("turns") or []
        n = len(turns)
        for i, t in enumerate(turns):
            text = str((t or {}).get("text", "")).strip()
            if not text:
                continue
            role = _norm_role(str((t or {}).get("role", "ayma")))
            stripped = _strip_photo_marker(text)
            if (role, text) in seen or (role, stripped) in seen:
                continue  # already have it from chat_messages OR an earlier
                # raw_turns doc/position in *this* pass (see below) — a real,
                # confirmed production shape (founder's account,
                # iWhWjiWhEpU7iyu9B9vy7GlT0PD2, 2026-09-26): a session's
                # persisted `turns` array can itself hold the same exact
                # (role, text) two or three times over — e.g. a Gemini Live
                # session restart mid-call replaying its whole running chat
                # context into the new connection, or two independent
                # writers (the client's own on-stop persist and the voice
                # agent's shutdown persist) racing on the same doc. Every
                # prior version of this loop only checked `seen` against
                # `chat_messages` and never added a raw_turns hit to it, so
                # each occurrence surfaced as its own transcript row on every
                # reload — and because that reloaded, still-duplicated
                # window is exactly what the client resends as `recent_turns`
                # on its next `/bootstrap`/`/chat` call, the duplication
                # re-entered `raw_turns` and compounded release over release
                # instead of ever self-correcting.
            if not stripped:
                continue  # a bare "shared a photo" — the chat_messages row owns it
            # Recorded *before* the append below so a second/third copy of the
            # exact same turn — whether later in this doc or in an older
            # session doc processed next (`rt` is newest-`updated_at` first,
            # so the freshest copy always wins) — is dropped instead of
            # echoed back into the transcript and, transitively, into the
            # next session's seeded history.
            seen.add((role, text))
            seen.add((role, stripped))
            text = stripped
            ts = (base - timedelta(seconds=(n - i))) if base else None
            out.append({
                "ts": ts,
                "role": role,
                "text": text[:_MAX_TEXT],
                "image_path": "",
            })

    return out


def recent(
    db, uid: str, *, before: datetime | None = None, limit: int = 40
) -> dict:
    """Up to ``limit`` messages older than ``before`` (or the latest), merged
    from ``chat_messages`` + ``raw_turns``, returned oldest-first, plus
    ``next_before`` — the ISO cursor for the next older page (``None`` at the
    start of history)."""
    limit = max(1, min(int(limit), _MAX_PAGE))
    if not uid:
        return {"messages": [], "next_before": None}

    items = _collect(db, uid)
    # A stable sort key: timestamped turns in time order, undated ones last.
    _far_past = datetime.min.replace(tzinfo=timezone.utc)
    items.sort(key=lambda m: m["ts"] or _far_past)

    if before is not None:
        b = before if before.tzinfo else before.replace(tzinfo=timezone.utc)
        items = [m for m in items if (m["ts"] or _far_past) < b]

    page = items[-limit:]
    messages = [
        {
            "role": m["role"],
            "text": m["text"],
            "image_path": m["image_path"],
            "created_at": m["ts"].isoformat() if m["ts"] else None,
            "tools": m.get("tools") or [],
            "subject_image": m.get("subject_image") or "",
        }
        for m in page
    ]

    next_before = None
    if len(items) > limit:
        for m in page:
            if m["ts"] is not None:
                next_before = m["ts"].isoformat()
                break
    return {"messages": messages, "next_before": next_before}
