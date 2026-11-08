"""Async voice messages: press, speak, release (Chunk A, staging).

The client records a wav clip, uploads it to ``uploads/{uid}/async_voice/``
whenever the connection allows (queued on the phone otherwise), and calls
``POST /voice/async``. This module runs the cloud half as a
disconnection-proof job and delivers the result two ways:

* the job doc ``users/{uid}/async_voice_jobs/{job_id}`` — the client watches
  it for live stage updates (``received`` → ``transcribing`` → ``thinking``
  → ``speaking`` → ``done`` / ``error``) and the reply payload;
* the durable thread — the user turn (transcript + clip) and Ayma's reply
  (text + spoken clip) are appended to ``chat_messages`` exactly like a
  ``/chat`` turn, so the reply lands in the same conversation thread,
  survives reloads, and feeds ``raw_turns`` like any other turn.

LiveKit-only inference (founder rule, permanent) — every leg below goes
through the LiveKit Inference gateway, the same endpoints live voice uses:

* STT: ``POST {gateway}/v1/chat/completions`` with the clip as ``input_audio``
  (``inference_llm`` via ``gemini.generate_json``) — the same transcription
  the gateway already does for DM voice notes;
* LLM: ``gemini.generate_reply`` — Inference-only; deliberately NOT the
  user's Brain provider (which may be Meta direct) and never with tools
  that need a direct provider;
* TTS: ``wss://{gateway}/v1/tts`` (``inference_tts.synthesize``) — the same
  endpoint and protocol as the live call's cascade TTS leg.

No direct-Google path exists here: an unsupported clip mime or a gateway
failure fails the job honestly (``tests/test_async_voice.py`` grep-gates
this file for direct-provider calls).
"""

from __future__ import annotations

import asyncio
import logging

import chat_history
import gemini
import inference_llm
import inference_tts
import session_mode
import token_ledger
import turn_caps
from config import CONFIG
from skills import make_session_tool_fns, session_tool_declarations
from transcript import ROLE_AYMA, ROLE_USER, Turn

logger = logging.getLogger("ayma.async_voice")

STATUS_RECEIVED = "received"
STATUS_TRANSCRIBING = "transcribing"
STATUS_THINKING = "thinking"
STATUS_SPEAKING = "speaking"
STATUS_DONE = "done"
STATUS_ERROR = "error"

TERMINAL_STATUSES = frozenset({STATUS_DONE, STATUS_ERROR})

_JOBS = "async_voice_jobs"
_REPLY_SUBDIR = "async_voice"

_TRANSCRIBE_INSTRUCTION = "Transcribe this voice message verbatim."
_TRANSCRIBE_SYSTEM = "You transcribe audio accurately."
_TRANSCRIBE_SCHEMA = {
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"],
}


def job_ref(db, uid: str, job_id: str):
    return (
        db.collection("users").document(uid).collection(_JOBS).document(job_id)
    )


def fetch_job(db, uid: str, job_id: str) -> dict | None:
    """The stored job doc, or ``None`` when this id never ran."""
    try:
        snap = job_ref(db, uid, job_id).get()
    except Exception:  # noqa: BLE001 - a read hiccup reads as "no job"
        return None
    return snap.to_dict() if snap.exists else None


def _server_ts():
    from firebase_admin import firestore

    return firestore.SERVER_TIMESTAMP


def _update_job(db, uid: str, job_id: str, **fields) -> None:
    try:
        job_ref(db, uid, job_id).set(
            {**fields, "updated_at": _server_ts()}, merge=True
        )
    except Exception:  # noqa: BLE001 - status writes never fail the job
        logger.exception("async_voice status write failed for %s", job_id)


def create_job(
    db, uid: str, job_id: str, storage_path: str, session_id: str
) -> None:
    job_ref(db, uid, job_id).set({
        "status": STATUS_RECEIVED,
        "storage_path": storage_path,
        "session_id": session_id,
        "transcript": "",
        "reply_text": "",
        "reply_audio_url": "",
        "reply_audio_path": "",
        "tools": [],
        "image_url": "",
        "error": "",
        "usage_capped": False,
        "capped": False,
        "created_at": _server_ts(),
        "updated_at": _server_ts(),
    })


async def _transcribe(
    uid: str, clip: bytes, mime: str, session_id: str
) -> str:
    """The clip's verbatim transcript via LiveKit Inference (STT leg).

    Same gateway call DM voice-note transcription already makes
    (``dm_ingest``): the wav rides ``chat/completions`` as ``input_audio``.
    The credit gate stays ON (a user-initiated turn): broke users get the
    honest out-of-credits job outcome, not a silent hang.
    """
    result = await gemini.generate_json(
        _TRANSCRIBE_INSTRUCTION,
        system_prompt=_TRANSCRIBE_SYSTEM,
        response_schema=_TRANSCRIBE_SCHEMA,
        image=(clip, mime),
        uid=uid,
        feature=token_ledger.FEATURE_VOICE,
        session_id=session_id,
    )
    if isinstance(result, dict):
        return str(result.get("text", "") or "").strip()
    return ""


async def _compose_prompt(db, uid: str, mode: str, window: list[Turn]) -> str:
    """Ayma's system prompt for the turn — the voice-seed composition
    (``POST /bootstrap``), so an async voice message thinks with exactly
    the context a live call would: persona (voice variant — the reply is
    spoken) + wiki + recent turns + interview/preference layers."""
    import ai_assessment
    import context_opt
    import prompt as prompt_module
    from prompt import compose_system_prompt
    from skills import app_control as app_control_mod
    from skills import set_model_stack
    from wiki_query import read_wiki_context

    # main.py owns these (shared with /chat and /bootstrap); a lazy import
    # keeps this module cycle-free at load time.
    import main

    prompt_turns = window
    summary_text = ""
    if context_opt.voice_seed_diet_enabled():
        prompt_turns = window[-context_opt.voice_tail_turns():]
        wiki_ctx = read_wiki_context(
            db, uid,
            max_chars=context_opt.core_wiki_chars(),
            include_page_types=context_opt.CORE_PAGE_TYPES,
        )
        summary_text = context_opt.stored_summary_text(db, uid)
    else:
        wiki_ctx = read_wiki_context(
            db, uid,
            exclude_page_types=ai_assessment.EXCLUDED_FROM_CHAT_CONTEXT,
        )
    prompt_text = compose_system_prompt(
        recent_turns=prompt_turns,
        wiki_context=wiki_ctx,
        session_mode=mode,
        profile_progress=main._interview_progress(uid, mode),  # noqa: SLF001 - shared helper
        preferences_context=main._preferences_context(uid, mode),  # noqa: SLF001 - shared helper
        questionnaire_note=main._questionnaire_note(uid, mode),  # noqa: SLF001 - shared helper
        model_stack_context=set_model_stack.model_stack_context(db, uid),
        app_accent_context=app_control_mod.accent_color_context(db, uid),
        db=db,
        summary_context=summary_text,
        variant="voice",
    )
    # Emotion matching (emotion.py): an async voice message is answered
    # from its transcript — the same standing guidance as live voice, so
    # the reply is written (and later spoken) already emotion-matched.
    import emotion as emotion_mod

    prompt_text = emotion_mod.apply_to_prompt(
        prompt_text, enabled=main._emotion_matching_enabled(uid)  # noqa: SLF001 - shared helper
    )
    return prompt_text + "\n\n" + prompt_module.voice_language_directive(
        main._ayma_voice_language(uid)  # noqa: SLF001 - shared helper
    )


def _fail(
    db, uid: str, job_id: str, error: str, transcript: str = "",
    usage_capped: bool = False, capped: bool = False,
) -> dict:
    _update_job(
        db, uid, job_id,
        status=STATUS_ERROR,
        error=error,
        transcript=transcript,
        usage_capped=usage_capped,
        capped=capped,
    )
    return {
        "job_id": job_id,
        "status": STATUS_ERROR,
        "transcript": transcript,
        "error": error,
        "usage_capped": usage_capped,
        "capped": capped,
    }


async def run_job(
    db,
    uid: str,
    *,
    job_id: str,
    storage_path: str,
    session_id: str,
    recent_turns: list[Turn],
    is_anonymous: bool,
) -> dict:
    """Run one async voice job to a terminal state; never raises.

    Returns the terminal payload (also written to the job doc). Every
    failure mode lands as an honest ``error`` outcome — the client resolves
    its loader to that copy instead of hanging.
    """
    import main  # noqa: PLC0415 - lazy: shared finalize helpers, no cycle

    window = list(recent_turns)

    # Turn cap — the same gate /chat enforces (marketing/interview modes).
    try:
        mode = session_mode.derive_for(db, uid, is_anonymous)
    except Exception:  # noqa: BLE001 - mirror /chat: read failure = marketing
        mode = session_mode.MODE_MARKETING
    cap = turn_caps.evaluate(db, uid, mode)
    if not cap.allowed:
        return _fail(
            db, uid, job_id,
            cap.canned_reply or "Ayma can't take a voice message right now.",
            capped=True,
        )

    if not storage_path.startswith(f"uploads/{uid}/"):
        return _fail(
            db, uid, job_id, "That recording isn't yours to transcribe."
        )

    from media_embed import download_bytes

    try:
        clip, mime = await asyncio.to_thread(download_bytes, storage_path)
    except Exception as exc:  # noqa: BLE001
        logger.warning("async_voice clip download failed for %s: %s", job_id, exc)
        return _fail(
            db, uid, job_id,
            "Ayma couldn't fetch your recording. Please try sending it again.",
        )
    if len(clip) > CONFIG.async_voice_max_clip_bytes:
        return _fail(
            db, uid, job_id,
            "That voice message is too long — keep it under a few minutes.",
        )
    if inference_llm.media_part(b"", mime) is None:
        return _fail(
            db, uid, job_id,
            "Ayma couldn't read that recording — try recording it again.",
        )

    # STT leg (LiveKit Inference).
    _update_job(db, uid, job_id, status=STATUS_TRANSCRIBING)
    try:
        transcript = await _transcribe(uid, clip, mime, session_id)
    except token_ledger.TokenCapExceeded:
        return _fail(
            db, uid, job_id,
            token_ledger.out_of_credits_message(token_ledger.CONTEXT_CHAT),
            usage_capped=True,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("async_voice transcription failed for %s: %s", job_id, exc)
        return _fail(
            db, uid, job_id,
            "Ayma couldn't make out that recording. Please try again.",
        )
    if not transcript:
        return _fail(
            db, uid, job_id,
            "Ayma couldn't hear anything in that recording. Please try again.",
        )

    # The user turn persists up front (mirrors /chat): a slow/failed rest of
    # the job never loses what the user said. Idempotent per job id.
    try:
        if not chat_history.user_turn_exists(db, uid, job_id):
            chat_history.append(
                db, uid, "user", transcript,
                audio_path=storage_path,
                client_msg_id=job_id,
            )
    except Exception:  # noqa: BLE001 - persistence never fails the job
        logger.exception("async_voice user-turn append failed for %s", job_id)

    # LLM leg (LiveKit Inference) — via gemini.generate_reply directly, NOT
    # the user's Brain provider: the async path is LiveKit-only by founder
    # rule, and the Brain may be a direct provider (Meta).
    _update_job(
        db, uid, job_id, status=STATUS_THINKING, transcript=transcript
    )
    try:
        system_prompt = await _compose_prompt(db, uid, mode, window)
    except Exception:  # noqa: BLE001
        logger.exception("async_voice prompt compose failed for %s", job_id)
        return _fail(
            db, uid, job_id,
            "Ayma couldn't think that one through. Please try again.",
            transcript=transcript,
        )
    image_sink: dict = {}
    feedback_sink: dict = {}
    try:
        reply = await gemini.generate_reply(
            transcript,
            system_prompt=system_prompt,
            tool_declarations=session_tool_declarations(),
            tool_fns=make_session_tool_fns(
                db, uid,
                session_ctx={
                    "session_id": session_id,
                    "turn_index": len(window),
                    "turns": window + [Turn(ROLE_USER, transcript)],
                },
                image_result=image_sink,
                feedback_result=feedback_sink,
            ),
            uid=uid,
            feature=token_ledger.FEATURE_VOICE,
            session_id=session_id,
        )
    except token_ledger.TokenCapExceeded:
        return _fail(
            db, uid, job_id,
            token_ledger.out_of_credits_message(token_ledger.CONTEXT_CHAT),
            transcript=transcript,
            usage_capped=True,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("async_voice reply failed for %s: %s", job_id, exc)
        return _fail(
            db, uid, job_id,
            "Ayma couldn't answer that one. Please try again.",
            transcript=transcript,
        )
    reply_text = (reply.text or "").strip()
    if not reply_text:
        return _fail(
            db, uid, job_id,
            "Ayma came up empty on that one. Please try again.",
            transcript=transcript,
        )

    # TTS leg (LiveKit Inference) — best-effort: a synthesis failure still
    # delivers the transcript reply, just without a playable clip.
    _update_job(
        db, uid, job_id, status=STATUS_SPEAKING, reply_text=reply_text
    )
    reply_audio_url = ""
    reply_audio_path = f"ayma_generated/{uid}/{_REPLY_SUBDIR}/{job_id}.wav"
    try:
        wav = await inference_tts.synthesize(reply_text)
        from firebase_admin import storage

        blob = storage.bucket(CONFIG.storage_bucket).blob(reply_audio_path)
        await asyncio.to_thread(
            blob.upload_from_string, wav, "audio/wav"
        )
        from public_profile import _photo_url  # noqa: PLC0415 - sibling helper

        reply_audio_url = await asyncio.to_thread(
            _photo_url, reply_audio_path
        ) or ""
    except Exception as exc:  # noqa: BLE001
        logger.warning("async_voice TTS failed for %s: %s", job_id, exc)
        reply_audio_path = ""

    tools_used = list(reply.tools_used or [])
    image_url = str(image_sink.get("image_url") or "")
    feedback_card = dict(feedback_sink) if feedback_sink else {}

    # Durable thread: the reply lands like a /chat turn (transcript + audio).
    try:
        chat_history.append(
            db, uid, "ayma", reply_text,
            audio_url=reply_audio_url or None,
            tools=tools_used or None,
            image_url=image_url or None,
            client_msg_id=job_id,
        )
    except Exception:  # noqa: BLE001
        logger.exception("async_voice reply append failed for %s", job_id)
    if session_id:
        try:
            main._persist_session(  # noqa: SLF001 - shared helper
                uid, session_id,
                window + [
                    Turn(ROLE_USER, transcript), Turn(ROLE_AYMA, reply_text)
                ],
            )
        except Exception:  # noqa: BLE001
            logger.exception("async_voice raw_turns failed for %s", job_id)

    try:
        import notifications_triggers

        await notifications_triggers.notify_ayma_reply(db, uid, reply_text)
    except Exception:  # noqa: BLE001 - best-effort by contract
        pass

    payload = {
        "job_id": job_id,
        "status": STATUS_DONE,
        "transcript": transcript,
        "reply_text": reply_text,
        "reply_audio_url": reply_audio_url,
        "reply_audio_path": reply_audio_path,
        "tools": tools_used,
        "image_url": image_url,
        "feedback_card": feedback_card or None,
    }
    _update_job(
        db, uid, job_id,
        status=STATUS_DONE,
        transcript=transcript,
        reply_text=reply_text,
        reply_audio_url=reply_audio_url,
        reply_audio_path=reply_audio_path,
        tools=tools_used,
        image_url=image_url,
        error="",
    )
    return payload
