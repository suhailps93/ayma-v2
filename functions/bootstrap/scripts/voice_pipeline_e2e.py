"""End-to-end voice-pipeline test — no device, just an audio file.

Exercises the whole live voice path:

    firebase auth -> POST /bootstrap -> LiveKit room -> agent worker
    -> Gemini Live -> transcripts + audio back

It joins the caller's room as the "user" participant, publishes a spoken WAV
(synthesised with Gemini TTS if none is given), and asserts that:

  1. the agent participant joins the room,
  2. Gemini Live transcribes our audio  (`user_transcript` data messages),
  3. Ayma replies in text               (`agent_transcript` data messages),
  4. Ayma replies in audio              (a subscribed agent audio track with
     real frames).

Run from the agent venv (it has `livekit.rtc`):

    cd functions/bootstrap
    set -a && . ../../.env.local && set +a          # GOOGLE_APPLICATION_CREDENTIALS, project
    . .venv-agent/bin/activate
    python scripts/voice_pipeline_e2e.py                     # TTS-synthesised prompt
    python scripts/voice_pipeline_e2e.py --wav my_prompt.wav # your own 16k/24k mono WAV

Env / flags:
  --api            Main API base URL (default: the deployed ayma-api)
  --web-api-key    Firebase Web API key for signInWithCustomToken
                   (default: the project's key, discovered via gcloud if unset)
  --uid            test uid (default: a random voice-e2e-* id, deleted after)
  --wav            path to a mono PCM16 WAV to speak instead of TTS
  --say            text to synthesise when --wav is not given
  --seconds        how long to listen for the reply after sending (default 25)
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import os
import subprocess
import sys
import urllib.request
import uuid
import wave

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DEFAULT_API = "https://ayma-api-235381544962.us-central1.run.app"
DEFAULT_KEY_RESOURCE = (
    "projects/235381544962/locations/global/keys/"
    "4b7184de-328a-4ba4-8bc5-250385d89e82"
)
DEFAULT_SAY = (
    "Hi Ayma, this is an automated voice test. Please say hello back to me "
    "and tell me one short fun fact."
)


# --------------------------------------------------------------------------- #
# auth + bootstrap
# --------------------------------------------------------------------------- #
def _web_api_key(explicit: str | None) -> str:
    if explicit:
        return explicit
    out = subprocess.run(
        ["gcloud", "services", "api-keys", "get-key-string", DEFAULT_KEY_RESOURCE,
         "--format=value(keyString)"],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


def _id_token(uid: str, web_key: str) -> str:
    from firebase_admin import auth

    custom = auth.create_custom_token(uid).decode()
    req = urllib.request.Request(
        "https://identitytoolkit.googleapis.com/v1/accounts:"
        f"signInWithCustomToken?key={web_key}",
        data=json.dumps({"token": custom, "returnSecureToken": True}).encode(),
        headers={"Content-Type": "application/json"},
    )
    return json.loads(urllib.request.urlopen(req).read())["idToken"]


def _bootstrap(api: str, id_token: str) -> dict:
    req = urllib.request.Request(
        f"{api}/bootstrap",
        data=json.dumps({"session_id": "voice-e2e", "recent_turns": []}).encode(),
        headers={"Authorization": f"Bearer {id_token}",
                 "Content-Type": "application/json"},
    )
    return json.loads(urllib.request.urlopen(req).read())


# --------------------------------------------------------------------------- #
# audio in
# --------------------------------------------------------------------------- #
def _load_wav(path: str) -> tuple[bytes, int]:
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1, "WAV must be mono"
        assert w.getsampwidth() == 2, "WAV must be 16-bit PCM"
        return w.readframes(w.getnframes()), w.getframerate()


def _tts(text: str) -> tuple[bytes, int]:
    """Synthesise `text` to PCM16 mono via Gemini TTS (Vertex). Returns
    (pcm_bytes, sample_rate)."""
    from config import CONFIG
    from google import genai
    from google.genai import types

    client = (
        genai.Client(vertexai=True, project=CONFIG.project_id or None,
                     location=CONFIG.vertex_location)
        if CONFIG.use_vertex else genai.Client()
    )
    resp = client.models.generate_content(
        model=CONFIG.gemini_tts_model,
        contents=text,
        config=types.GenerateContentConfig(
            response_modalities=["AUDIO"],
            speech_config=types.SpeechConfig(
                voice_config=types.VoiceConfig(
                    prebuilt_voice_config=types.PrebuiltVoiceConfig(
                        voice_name="Kore"
                    )
                )
            ),
        ),
    )
    part = resp.candidates[0].content.parts[0]
    data = part.inline_data.data
    mime = (part.inline_data.mime_type or "").lower()
    rate = 24000
    for tok in mime.split(";"):
        if tok.strip().startswith("rate="):
            rate = int(tok.split("=")[1])
    return data, rate


# --------------------------------------------------------------------------- #
# the test
# --------------------------------------------------------------------------- #
async def run(args, uid: str) -> int:
    import firebase_admin
    import livekit.rtc as rtc

    if not firebase_admin._apps:
        firebase_admin.initialize_app()

    print(f"• uid           {uid}")

    web_key = _web_api_key(args.web_api_key)
    tok = _id_token(uid, web_key)
    boot = _bootstrap(args.api, tok)
    lk = boot.get("livekit") or {}
    if not lk.get("url") or not lk.get("token"):
        print("FAIL: /bootstrap returned no LiveKit credentials:", boot)
        return 1
    print(f"• session_mode  {boot.get('session_mode')}")
    print(f"• room          {lk['room']}  ({lk['url']})")

    if args.wav:
        pcm, rate = _load_wav(args.wav)
        print(f"• prompt        WAV {args.wav}  ({len(pcm)} bytes @ {rate} Hz)")
    else:
        print("• prompt        synthesising with Gemini TTS…")
        pcm, rate = _tts(args.say)
        print(f"                {len(pcm)} bytes @ {rate} Hz")

    room = rtc.Room()
    state = {
        "agent_identity": None,
        "user_tx": [],
        "agent_tx": [],
        "agent_states": [],
        "agent_audio_frames": 0,
        "agent_audio_bytes": 0,
    }
    agent_joined = asyncio.Event()
    audio_tasks: list[asyncio.Task] = []

    @room.on("participant_connected")
    def _pc(p: rtc.RemoteParticipant) -> None:
        state["agent_identity"] = p.identity
        print(f"  ← participant joined: {p.identity}")
        agent_joined.set()

    @room.on("data_received")
    def _data(dp: rtc.DataPacket) -> None:
        try:
            msg = json.loads(bytes(dp.data).decode())
        except Exception:
            return
        topic = dp.topic or ""
        if topic == "user_transcript" and msg.get("text"):
            state["user_tx"].append(msg["text"])
        elif topic == "agent_transcript" and msg.get("text"):
            state["agent_tx"].append(msg["text"])
            print(f"  ← agent_transcript: {msg['text']!r}")
        elif topic == "agent_state":
            state["agent_states"].append(msg.get("state"))

    @room.on("track_subscribed")
    def _track(track: rtc.Track, pub, participant) -> None:
        if track.kind != rtc.TrackKind.KIND_AUDIO:
            return
        print(f"  ← subscribed to agent audio track from {participant.identity}")

        async def _read() -> None:
            stream = rtc.AudioStream(track, sample_rate=24000, num_channels=1)
            async for ev in stream:
                f = ev.frame
                state["agent_audio_frames"] += 1
                state["agent_audio_bytes"] += len(f.data)

        audio_tasks.append(asyncio.create_task(_read()))

    await room.connect(lk["url"], lk["token"])
    print("• connected to room")

    source = rtc.AudioSource(rate, 1)
    track = rtc.LocalAudioTrack.create_audio_track("voice-e2e-mic", source)
    await room.local_participant.publish_track(
        track,
        rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE),
    )
    print("• published mic track")

    try:
        await asyncio.wait_for(agent_joined.wait(), timeout=25)
    except asyncio.TimeoutError:
        print("FAIL: the agent worker never joined the room within 25s "
              "(is ayma-agent running / registered?)")
        await room.disconnect()
        return 1

    # stream the prompt at real time, 20 ms frames
    frame_ms = 20
    frame_samples = rate * frame_ms // 1000
    frame_bytes = frame_samples * 2
    print(f"• streaming prompt ({len(pcm)//frame_bytes} frames)…")
    for i in range(0, len(pcm) - frame_bytes + 1, frame_bytes):
        await source.capture_frame(
            rtc.AudioFrame(pcm[i:i + frame_bytes], rate, 1, frame_samples)
        )
        await asyncio.sleep(frame_ms / 1000)
    # ~1s of silence so end-of-utterance is detected
    silence = b"\x00" * frame_bytes
    for _ in range(50):
        await source.capture_frame(
            rtc.AudioFrame(silence, rate, 1, frame_samples)
        )
        await asyncio.sleep(frame_ms / 1000)

    print(f"• listening {args.seconds}s for Ayma's reply…")
    await asyncio.sleep(args.seconds)

    for t in audio_tasks:
        t.cancel()
    with contextlib.suppress(Exception):
        await asyncio.gather(*audio_tasks, return_exceptions=True)
    await room.disconnect()

    # ---- verdict -------------------------------------------------------- #
    print("\n──────── result ────────")
    print(f"agent joined ............ {bool(state['agent_identity'])}"
          f"  ({state['agent_identity']})")
    print(f"user transcript ......... {len(state['user_tx'])} msg  "
          f"{' '.join(state['user_tx'])[:120]!r}")
    print(f"agent transcript ........ {len(state['agent_tx'])} msg  "
          f"{' '.join(state['agent_tx'])[:160]!r}")
    print(f"agent audio ............. {state['agent_audio_frames']} frames / "
          f"{state['agent_audio_bytes']} bytes")
    print(f"agent states ............ {state['agent_states']}")

    checks = {
        "agent joined": bool(state["agent_identity"]),
        "our speech transcribed": len(state["user_tx"]) > 0,
        "Ayma replied (text)": len(state["agent_tx"]) > 0,
        "Ayma replied (audio)": state["agent_audio_frames"] > 5,
    }
    ok = all(checks.values())
    print("────────────────────────")
    for name, passed in checks.items():
        print(f"  [{'PASS' if passed else 'FAIL'}] {name}")
    print("────────────────────────")
    print("VOICE PIPELINE:", "PASS ✅" if ok else "FAIL ❌")
    return 0 if ok else 1


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--api", default=DEFAULT_API)
    ap.add_argument("--web-api-key", default=None)
    ap.add_argument("--uid", default=None)
    ap.add_argument("--wav", default=None)
    ap.add_argument("--say", default=DEFAULT_SAY)
    ap.add_argument("--seconds", type=int, default=25)
    args = ap.parse_args()

    generated = args.uid is None
    uid = args.uid or f"voice-e2e-{uuid.uuid4().hex[:8]}"

    rc = 1
    try:
        rc = asyncio.run(run(args, uid))
    finally:
        if generated:
            with contextlib.suppress(Exception):
                import firebase_admin
                from firebase_admin import auth, firestore

                if not firebase_admin._apps:
                    firebase_admin.initialize_app()
                db = firestore.client()
                u = db.collection("users").document(uid)
                for c in ("raw_turns", "wiki_pages", "pending_questions"):
                    for d in u.collection(c).stream():
                        d.reference.delete()
                u.delete()
                auth.delete_user(uid)
                print(f"• cleaned up {uid}")
    sys.exit(rc)


if __name__ == "__main__":
    main()
