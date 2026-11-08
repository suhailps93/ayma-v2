"""Build the voice-preview library for EVERY voice Ayma offers.

Founder decision (2026-11-07): the voice picker gets a recorded preview for
every voice, not just the built-in Gemini presets. This script synthesizes
the one standard sample line (``prompts/voice_preview.txt`` — the same line
the Gemini preset clips speak, so voices stay comparable) for each named
voice in the voice catalog that lacks a clip, and uploads it to
``voice_previews/{voice_id}.wav`` in the app Storage buckets — exactly where
:mod:`voice_preview` serves from.

HARD RULE (founder, permanent): synthesis goes through the LiveKit
Inference route ONLY (``livekit.agents.inference.TTS`` — the same gateway
class the voice agent builds its cascade TTS leg with, ``agent.py``
``build_cascade_session``). Never a direct provider API. A voice that
cannot be synthesized through LiveKit is reported with the exact reason,
never faked:

* realtime-model voices (OpenAI Realtime) are speech-to-speech — LiveKit
  Inference has no TTS model for them, so there is nothing to synthesize
  with;
* the ``""`` vendor-default entries have no voice id to key a clip to (the
  picker's preview button is a no-op for them by design);
* a TTS entry the catalog marks unavailable (e.g. cartesia — "needs
  LiveKit credits") is skipped, not synthesized against a dead route.

Run with the AGENT venv (it carries livekit-agents) from
``functions/bootstrap``::

    LIVEKIT_API_KEY=… LIVEKIT_API_SECRET=… \\
      .venv-agent/bin/python scripts/generate_voice_previews.py [--dry-run]

The LiveKit creds are the project's own (Secret Manager LIVEKIT_API_KEY /
LIVEKIT_API_SECRET, or the _STAGING pair for the staging project). Storage
uses ADC, like every other fleet script. Idempotent: a voice whose clip
already exists in a bucket is left untouched there.
"""

from __future__ import annotations

import argparse
import asyncio
import io
import os
import sys
import uuid
import wave
from pathlib import Path

_BOOTSTRAP = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_BOOTSTRAP))

_STORAGE_PREFIX = "voice_previews"
_DEFAULT_BUCKETS = ("ayma-staging.firebasestorage.app", "ayma-ai.firebasestorage.app")


def _sample_text() -> str:
    text = (_BOOTSTRAP / "prompts" / "voice_preview.txt").read_text(
        encoding="utf-8"
    ).strip()
    if not text:
        raise RuntimeError("empty voice preview script")
    return text


def _wav_bytes(pcm: bytes, rate: int, channels: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)  # LiveKit frames are signed 16-bit PCM
        wav.setframerate(rate)
        wav.writeframes(pcm)
    return buf.getvalue()


async def _synthesize_through_livekit(tts_id: str, voice_id: str, text: str) -> bytes:
    """One clip through the LiveKit Inference gateway — the same
    ``inference.TTS`` the agent's cascade sessions are built from."""
    from livekit.agents import inference
    from livekit.agents.utils import http_context

    # Outside an agent worker the SDK has no ambient HTTP session; open one
    # explicitly or every synthesis fails with "http session outside of a
    # job context" (and retries pointlessly).
    async with http_context.open():
        tts = inference.TTS(model=tts_id, voice=voice_id)
        try:
            frame = await tts.synthesize(text).collect()
        finally:
            await tts.aclose()
    pcm = bytes(frame.data)
    if not pcm:
        raise RuntimeError("LiveKit TTS returned no audio")
    return _wav_bytes(pcm, frame.sample_rate, frame.num_channels)


def _plan() -> tuple[list[tuple[str, str, str]], list[tuple[str, str]]]:
    """(to_generate, report_only) from the live voice catalog.

    ``to_generate``: ``(tts_id, voice_id, label)`` for every named voice of
    every AVAILABLE cascade TTS. ``report_only``: ``(subject, reason)`` for
    everything else the catalog offers, so the run accounts for every voice
    the app can show."""
    import voice_catalog

    cat = voice_catalog.catalog()
    generate: list[tuple[str, str, str]] = []
    report: list[tuple[str, str]] = []
    for m in cat["realtime_models"]:  # type: ignore[union-attr]
        for v in m["voices"]:  # type: ignore[union-attr]
            if not v["id"]:
                report.append(
                    (f"{m['id']} (default)", "vendor-default entry — no voice id to key a clip to")
                )
            elif m["id"] == voice_catalog.REALTIME_GEMINI:
                report.append(
                    (f"gemini-live/{v['id']}", "Gemini preset — clip recorded with the original library")
                )
            else:
                report.append(
                    (
                        f"{m['id']}/{v['id']}",
                        "realtime speech-to-speech voice — LiveKit Inference has no TTS model for it",
                    )
                )
    for t in cat["tts"]:  # type: ignore[union-attr]
        named = [v for v in t["voices"] if v["id"]]  # type: ignore[union-attr]
        if not t["available"]:  # type: ignore[union-attr]
            for v in named:
                report.append(
                    (f"{t['id']}/{v['id']}", f"TTS marked unavailable ({t['requires_secret'] or 'not credited'})")
                )
            if not named:
                report.append(
                    (str(t["id"]), f"unavailable ({t['requires_secret'] or 'not credited'}) and no named voices in the catalog")
                )
            continue
        for v in t["voices"]:  # type: ignore[union-attr]
            if not v["id"]:
                report.append(
                    (f"{t['id']} (default)", "vendor-default entry — no voice id to key a clip to")
                )
            else:
                generate.append((str(t["id"]), str(v["id"]), str(v["label"])))
    return generate, report


async def _run(buckets: list[str], dry_run: bool) -> int:
    from google.cloud import storage

    text = _sample_text()
    generate, report = _plan()
    print(f"sample line: {text!r}")
    print(f"buckets: {', '.join(buckets)}")
    for subject, reason in report:
        print(f"REPORT-ONLY  {subject}: {reason}")

    client = storage.Client()
    stores = {name: client.bucket(name) for name in buckets}

    failures = 0
    for tts_id, voice_id, label in generate:
        blob_name = f"{_STORAGE_PREFIX}/{voice_id}.wav"
        missing = [b for b in buckets if not stores[b].blob(blob_name).exists()]
        if not missing:
            print(f"EXISTS       {tts_id}/{label} ({voice_id}) in all buckets")
            continue
        if dry_run:
            print(f"WOULD-GEN    {tts_id}/{label} ({voice_id}) -> {', '.join(missing)}")
            continue
        try:
            wav = await _synthesize_through_livekit(tts_id, voice_id, text)
        except Exception as exc:  # noqa: BLE001 - report the exact reason
            failures += 1
            print(f"FAILED       {tts_id}/{label} ({voice_id}): {type(exc).__name__}: {exc}")
            continue
        for bucket_name in missing:
            blob = stores[bucket_name].blob(blob_name)
            blob.metadata = {"firebaseStorageDownloadTokens": str(uuid.uuid4())}
            blob.upload_from_string(wav, content_type="audio/wav")
        print(f"GENERATED    {tts_id}/{label} ({voice_id}) {len(wav)} bytes -> {', '.join(missing)}")
    print(f"done: {len(generate)} catalog voices planned, {failures} synthesis failures")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--buckets",
        default=",".join(_DEFAULT_BUCKETS),
        help="comma-separated Storage buckets to fill",
    )
    args = parser.parse_args()
    if not (os.getenv("LIVEKIT_API_KEY") and os.getenv("LIVEKIT_API_SECRET")):
        print("LIVEKIT_API_KEY / LIVEKIT_API_SECRET must be set (project creds)", file=sys.stderr)
        return 2
    buckets = [b.strip() for b in args.buckets.split(",") if b.strip()]
    return asyncio.run(_run(buckets, args.dry_run))


if __name__ == "__main__":
    raise SystemExit(main())
