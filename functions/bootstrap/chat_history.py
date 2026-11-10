"""The user-visible Ayma-tab transcript.

Two sources, merged by :func:`recent`:

* ``users/{uid}/chat_messages/{id}`` — one doc per **text** message, written by
  ``POST /chat``. Carries a per-message ``created_at`` and any
  ``uploads/{uid}/…`` ``image_path`` (the client resolves it to a URL). An
  Ayma-generated image (``generate_image``/``edit_photo`` →
  ``ayma_generated/{uid}/…``) additionally carries ``image_url``, the durable
  token download URL: Storage rules only let the client SDK read
  ``uploads/{uid}``, so a generated image's path is *not* client-resolvable —
  the persisted URL (or the server-side fallback in :func:`_collect`) is what
  keeps it rendering after a reload (founder bug 2026-09-27: a generated
  image vanished from the transcript on reopen).
* ``users/{uid}/raw_turns/{sessionId}`` — the per-session substrate wiki ingest
  reads: one doc per session holding the full interleaved **voice + text**
  window (``turns: [{role, text, created_at?}]``). This is where voice
  conversations, Ayma's re-engagement check-ins, and any text that predates
  ``chat_messages`` live. Each turn carries its own ISO-8601 ``created_at`` —
  stamped by the voice agent as the turn is spoken (§1.7 step 8) — so a reload
  shows every voice turn's real time; a legacy turn with none falls back to the
  session doc's ``updated_at`` minus a per-index second (founder bug
  2026-11-09: a whole session otherwise collapsed onto one minute).

``recent`` flattens both onto one timeline so the transcript shows everything
the user has actually said to Ayma, not just post-feature text.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from firebase_admin import firestore

from transcript import strip_speech_markup

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
    image_url: str | None = None,
    audio_path: str | None = None,
    audio_url: str | None = None,
    tools: list[str] | None = None,
    subject_image: str | None = None,
    client_msg_id: str | None = None,
    shared_card: dict | None = None,
) -> None:
    """Append one message. No-op for an unknown role or an empty text with no
    image. Best-effort — callers wrap it so a write failure never fails /chat.

    ``image_url`` is the durable token download URL for an image the client
    can't resolve itself — an Ayma-generated ``ayma_generated/{uid}/…`` path,
    which Storage rules hide from the client SDK. Persist it alongside
    ``image_path`` so the image survives a reload. ``audio_path`` /
    ``audio_url`` are the same pair for an async voice-message turn
    (``async_voice.py``): the user's recorded clip (an ``uploads/{uid}/…``
    path the client SDK resolves itself) and Ayma's spoken reply (an
    ``ayma_generated/{uid}/…`` path that needs the durable token URL).
    ``tools`` are the user-facing labels for what Ayma did on this turn
    ("Searched the web", "Researched Jane Doe online") — persisted so the
    kicker survives a reload. ``subject_image`` is a resolved photo URL for
    the person a skill was run on (Explore deep-dive) so the history row can
    show their face.
    ``shared_card`` is the Send-to-Ayma card posted with a *user* send
    (``{"kind", "uid", "name", "photo", "ref_id"}`` — the reply-style card
    the chat renders above the message): persisted on the row so the card
    itself survives a reload. Without it the reloaded transcript showed
    only the message text (for a card-alone send, the bare ``[shared …]``
    wire label) and the tappable card was gone (founder bug 2026-11-09).
    It carries the card's identity only — never the shared page's contents.
    ``client_msg_id`` is the client-generated id of the *user send* this row
    belongs to — stamped on BOTH the user turn and its reply so a client that
    lost its connection mid-request can later find the finished turn in
    history by exact id (no text heuristics), and so a retried send can be
    answered from the persisted reply instead of re-billed
    (:func:`reply_for_client_id`).
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
        "image_url": image_url or "",
        "audio_path": audio_path or "",
        "audio_url": audio_url or "",
        "created_at": firestore.SERVER_TIMESTAMP,
    }
    labels = [str(t).strip() for t in (tools or []) if str(t).strip()]
    if labels:
        doc["tools"] = labels[:6]
    if subject_image:
        doc["subject_image"] = str(subject_image)
    card = shared_card or {}
    if role == "user" and str(card.get("kind", "")).strip():
        doc["shared_card_kind"] = str(card.get("kind", "")).strip()
        doc["shared_card_uid"] = str(card.get("uid", "") or "")
        doc["shared_card_name"] = str(card.get("name", "") or "")
        doc["shared_card_photo"] = str(card.get("photo", "") or "")
        doc["shared_card_ref_id"] = str(card.get("ref_id", "") or "")
    if client_msg_id:
        doc["client_msg_id"] = str(client_msg_id)
    _user(db, uid).collection("chat_messages").add(doc)


def reply_for_client_id(db, uid: str, client_msg_id: str) -> dict | None:
    """The persisted Ayma reply for the user send tagged ``client_msg_id``,
    or ``None`` if that turn never finished (or never arrived).

    The idempotency read behind a retried ``/chat``: a send whose connection
    died client-side may still have completed and been billed server-side —
    if its reply is already in ``chat_messages``, the retry is answered from
    here instead of generating (and billing) the whole turn again."""
    if not uid or not client_msg_id:
        return None
    try:
        docs = list(
            _user(db, uid)
            .collection("chat_messages")
            .where("client_msg_id", "==", str(client_msg_id))
            .stream()
        )
    except Exception:  # noqa: BLE001 - a read hiccup must never fail /chat
        return None
    for doc in docs:
        d = doc.to_dict() or {}
        if str(d.get("role", "")) == "ayma":
            return {
                "text": str(d.get("text", "")),
                "tools": [
                    str(t) for t in (d.get("tools") or []) if str(t).strip()
                ],
                "image_url": str(d.get("image_url", "")),
            }
    return None


def user_turn_exists(db, uid: str, client_msg_id: str) -> bool:
    """Whether the *user* row for ``client_msg_id`` is already persisted.

    The idempotency read behind persisting the user turn at turn START (so a
    slow/failed turn never loses the user's message): a retry of a send whose
    first attempt already recorded the user row must not record it twice."""
    if not uid or not client_msg_id:
        return False
    try:
        docs = list(
            _user(db, uid)
            .collection("chat_messages")
            .where("client_msg_id", "==", str(client_msg_id))
            .stream()
        )
    except Exception:  # noqa: BLE001 - a read hiccup must never fail /chat
        return False
    return any(str((d.to_dict() or {}).get("role", "")) == "user" for d in docs)


# Generated-image URL derivations, cached per path for the process lifetime —
# the blobs are immutable (one uuid-named upload, never rewritten), so a URL
# derived once stays right, and a history page reload doesn't re-hit Storage.
_GENERATED_URL_CACHE: dict[str, str] = {}


def _generated_image_url(path: str) -> str:
    """Server-resolved durable download URL for a pre-``image_url`` legacy row
    whose image lives outside ``uploads/{uid}`` (i.e. ``ayma_generated/…``).

    The client SDK can't resolve these paths — Storage rules only open
    ``uploads/{uid}`` / ``verification/{uid}`` — but the Admin SDK bypasses
    rules, so deriving the token URL here (``public_profile._photo_url``, the
    same helper that minted the URL at generation time) retroactively fixes
    every generated image persisted before ``image_url`` existed, no backfill
    needed. Best-effort: a deleted blob or a Storage hiccup yields ``""`` and
    the row renders text-only, exactly as before."""
    if not path:
        return ""
    cached = _GENERATED_URL_CACHE.get(path)
    if cached is not None:
        return cached
    try:
        from public_profile import _photo_url

        url = _photo_url(path) or ""
    except Exception:  # noqa: BLE001 - never fail a history load over one image
        url = ""
    if url:  # don't cache failures — a transient error may succeed next load
        _GENERATED_URL_CACHE[path] = url
    return url


def _as_dt(v):
    return v if hasattr(v, "isoformat") else None


def _parse_iso(v) -> datetime | None:
    """Parse a per-turn ISO-8601 ``created_at`` string into a tz-aware
    datetime, or ``None`` if it is missing/unparseable (the caller then falls
    back to the session-doc timestamp)."""
    if not isinstance(v, str) or not v.strip():
        return None
    try:
        dt = datetime.fromisoformat(v.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _norm_role(r: str) -> str:
    return "user" if r == "user" else "ayma"


def _collect(db, uid: str) -> list[dict]:
    """Every turn from both sources as ``{ts, role, text, image_path}`` dicts,
    newest-first is *not* guaranteed here — the caller sorts."""
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()
    seen_long: list[tuple[str, str]] = []

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
        image_url = str(d.get("image_url", ""))
        if image_path and not image_url and not image_path.startswith("uploads/"):
            # A generated image (ayma_generated/…) persisted before image_url
            # existed: the client can't resolve that path (Storage rules), so
            # derive the durable URL server-side or the image is lost on reload.
            image_url = _generated_image_url(image_path)
        # de-dup keys against the raw_turns pass: the bare text, and the text
        # with a photo marker (that's how _persist_session records image turns).
        cleaned_text = text.strip()
        stripped_text = _strip_photo_marker(text)
        seen.add((role, cleaned_text))
        seen.add((role, stripped_text))
        if len(cleaned_text) >= 500:
            seen_long.append((role, cleaned_text))
        if len(stripped_text) >= 500:
            seen_long.append((role, stripped_text))
        out.append({
            "ts": ts,
            "role": role,
            "text": text[:_MAX_TEXT],
            "image_path": image_path,
            "image_url": image_url,
            "audio_path": str(d.get("audio_path", "")),
            "audio_url": str(d.get("audio_url", "")),
            "tools": [str(t) for t in (d.get("tools") or []) if str(t).strip()],
            "subject_image": str(d.get("subject_image", "")),
            "client_msg_id": str(d.get("client_msg_id", "")),
            "shared_card_kind": str(d.get("shared_card_kind", "")),
            "shared_card_uid": str(d.get("shared_card_uid", "")),
            "shared_card_name": str(d.get("shared_card_name", "")),
            "shared_card_photo": str(d.get("shared_card_photo", "")),
            "shared_card_ref_id": str(d.get("shared_card_ref_id", "")),
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
        # DM ingest and the photo pipeline reuse persist_raw_turns purely to
        # give the wiki pipeline a substrate, keyed `dm-{threadId}-{msgId}`
        # (dm_ingest) and `photo-{mediaId}` (photo_pipeline — an internal
        # photo-context annotation like "(shared a photo of themselves) …").
        # Neither is an Ayma-chat turn — project them and a DM you sent, or an
        # internal photo-context record, surfaces in the Ayma transcript as a
        # user bubble (founder bug R2-D3: the "(shared a photo …) …" annotation
        # rendered as a pink user message in history).
        if doc.id.startswith("dm-") or doc.id.startswith("photo-"):
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
            if role == "ayma":
                # Clean any speech-control markup that reached a legacy
                # persisted turn before the agent-side strip existed — a turn
                # that was nothing but markup ("<no speech>{pause}") drops out
                # here instead of resurfacing as a chat bubble on reload
                # (founder bug 2026-11-09).
                text = strip_speech_markup(text)
                if not text:
                    continue
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
            # Long turn clamped to TurnModel cap (4000) or client budget:
            # chat_messages stores up to _MAX_TEXT (8000), while raw_turns
            # stores recent_turns clamped to ~4000 (clampRecentTurns /
            # TurnModel._truncate_caps in main.py). Prefix-match against seen
            # long turns so an over-long turn does not evade deduplication and
            # resurrect with a synthetic timestamp that displaces user sends
            # (ledger 2cw / Scout NOTE 140).
            if len(text) >= 500 and any(
                r == role and (s.startswith(text) or text.startswith(s))
                for r, s in seen_long
            ):
                continue
            if len(stripped) >= 500 and any(
                r == role and (s.startswith(stripped) or stripped.startswith(s))
                for r, s in seen_long
            ):
                continue
            if not stripped:
                continue  # a bare "shared a photo" — the chat_messages row owns it
            # Each turn's own real time, stamped by the voice agent when it was
            # spoken (founder bug 2026-11-09). Only legacy turns with no per-turn
            # time fall back to the session-doc `updated_at` minus a per-index
            # second — the old behavior that collapsed a whole session onto the
            # single session minute.
            per_turn_ts = _parse_iso((t or {}).get("created_at"))
            # Recorded *before* the append below so a second/third copy of the
            # exact same turn — whether later in this doc or in an older
            # session doc processed next (`rt` is newest-`updated_at` first,
            # so the freshest copy always wins) — is dropped instead of
            # echoed back into the transcript and, transitively, into the
            # next session's seeded history.
            seen.add((role, text))
            seen.add((role, stripped))
            if len(text) >= 500:
                seen_long.append((role, text))
            if len(stripped) >= 500:
                seen_long.append((role, stripped))
            text = stripped
            if per_turn_ts is not None:
                ts = per_turn_ts
            else:
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
            "image_url": m.get("image_url") or "",
            "audio_path": m.get("audio_path") or "",
            "audio_url": m.get("audio_url") or "",
            "created_at": m["ts"].isoformat() if m["ts"] else None,
            "tools": m.get("tools") or [],
            "subject_image": m.get("subject_image") or "",
            "client_msg_id": m.get("client_msg_id") or "",
            "shared_card_kind": m.get("shared_card_kind") or "",
            "shared_card_uid": m.get("shared_card_uid") or "",
            "shared_card_name": m.get("shared_card_name") or "",
            "shared_card_photo": m.get("shared_card_photo") or "",
            "shared_card_ref_id": m.get("shared_card_ref_id") or "",
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
