# Emotion-Matched Responses — Design

Founder directive (2026-11-06 ~00:11 PT): *"Make it match the user's
emotions and adjust the response accordingly. Use that feature for
everything including realtime."*

Ayma continuously reads the user's emotional state and meets it — reply
content, tone, and voice delivery — across text chat, cascade voice, and
realtime voice. Everything below is behind the `emotion_matching`
feature flag (default OFF; `feature_flags.py` registry,
`docs/FEATURE_FLAGS.md`). Main/prod untouched — staging only.

## 1. Detection

### (a) Transcript-based read (the layer built here)

One label set everywhere (`functions/bootstrap/emotion.py`):

`neutral · upbeat · playful · frustrated · sad · anxious · tired`
plus `intensity ∈ {low, medium, high}` and a separate boolean
`distress` (care routing, §3). Small on purpose: these are the states
Ayma can usefully *do* something different for.

Where the read happens, per surface — always folded into a pass that
already runs:

| Surface | Read | Extra gateway calls |
|---|---|---|
| Cascade voice | The voice-actions skill pass (`skills/voice_actions.py` `interpret_voice_action`, one LiveKit-Inference JSON call per finalized turn) gains `emotion` / `emotion_intensity` / `distress` fields in the SAME `RESPONSE_SCHEMA` / response | **0** |
| Text chat (`/chat`, `/chat/stream`) | The reply-generating brain pass itself: `main._prepare_chat` appends `emotion.guidance_block()` to that turn's system prompt, so the brain reads the latest message as part of composing its reply | **0** |
| Async voice messages | Same guidance block in `async_voice._compose_prompt` (the reply is generated from the transcript) | **0** |
| Realtime voice | No transcript pass exists (speech-to-speech); see §1(b) + the seed guidance below | **0** |

State lives in `emotion.EmotionState`: one in-memory instance per
voice session (created in `agent._start_main_cascade_session`), updated
once per finalized turn from the verdict, with turn-based decay
(a non-neutral read holds for 3 further turns; neutral reads let the
clock run instead of clearing instantly). **Session-scoped only —
nothing is written to Firestore or the user profile** (see §3 for the
open privacy question). In text chat there is no server-side state at
all: the brain re-reads from the latest message + recent-turns window
already in its context each turn.

### (b) Voice prosody — what the legs actually return

Checked against the code and the installed packages, not assumed:

- **Cascade STT legs return transcript text only.** Deepgram Nova-3
  (`deepgram/nova-3`, `config.py` `META_CASCADE_STT_MODEL`) is built via
  `inference.STT(model, language)` in `agent.build_cascade_session` —
  no sentiment option is requested, and the LiveKit Inference STT event
  surface carries no sentiment field back to us. Cartesia Ink
  (`_build_cartesia_stt`) likewise: the 1.8.9 plugin's STT has no
  sentiment/prosody output (grep of the installed plugin: no
  `sentiment` anywhere). AssemblyAI's streaming model can return
  sentiment upstream, but not through the Inference construction we use.
  **Conclusion: on the cascade, prosody is not available to us today;
  the transcript read in §1(a) is the signal.** If a future STT leg
  exposes per-utterance sentiment through LiveKit, it should feed the
  same `EmotionState` (the state's `update()` already accepts any
  `EmotionRead` source).
- **Realtime (Gemini Live via LiveKit Inference): affective dialogue is
  native and, on our model, always on.** Our realtime model is
  `google/gemini-3.8-live` (`config.py` `inference_live_model`).
  Google's Gemini 3.8 Live guide: affective dialogue is *enabled by
  default* in 3.8 Live — the model listens to acoustic prosody,
  emotional cues, pauses and inflection and adjusts vocal tone, empathy
  and rhythm; the legacy `enable_affective_dialog` flag was *removed*
  for 3.8 (it only ever applied to `gemini-live-2.5-flash-native-audio`,
  where it had to be set explicitly). Our own gateway probe notes agree
  there is nothing to set: `agent.build_inference_realtime_model`
  documents that Gemini-specific options (affective dialog, proactivity,
  temperature, …) are *silently ignored* by the LiveKit Inference
  gateway, so none are passed. The stale `GEMINI_LIVE_AFFECTIVE_DIALOG`
  config (default false) is inert on this path and is left alone.
  **So realtime already hears emotion natively; what we add is
  steering** — the standing guidance block rides the session seed
  (`main.py` voice-seed composition → `RoomSeed.system_prompt` →
  session instructions), telling the model how to meet each state and
  when to switch to care behaviour.
  **Isolation verdict:** the seed is built by the API serving the room —
  staging rooms are seeded by the staging API, prod rooms by the prod
  API. Shipping this code to staging only therefore changes staging
  realtime behaviour only, even though the hosted LiveKit worker
  (`ayma-lk`) is shared with prod. No hosted-worker config change is
  needed or made. Remaining verification: Scout's live-call pass
  (affective *quality* through the gateway can only be judged by
  listening — see the Scout script).
- Practice/avatar persona sessions are deliberately out of scope: the
  simulated match stays in character (its persona prompt governs it);
  emotion matching applies to **Ayma's** responses to the user.

## 2. Response adjustment

### (a) The brain's reply

- **Standing guidance** (`emotion.guidance_block()`, appended to the
  system prompt when the flag is on): match energy, never out-emote the
  user, de-escalate frustration, soften for sadness, steady for anxiety,
  low-effort for tired, celebrate wins briefly; never name the detection
  mechanically ("you seem sad") unless it fits naturally.
- **Per-turn context line** (cascade voice): `emotion.context_line()`
  renders the current state as one internal line — e.g. *"the user's
  current state reads as frustrated (high). Adjust: stay calm and
  unhurried, acknowledge the friction plainly … name the concrete next
  step"* — injected by `_EmotionAgent.on_user_turn_completed` into the
  temporary per-generation chat context (livekit-agents 1.8.9 passes a
  mutable copy that is discarded after the generation, so the line
  colours one reply and never pollutes history). Timing note: the
  voice-actions pass runs in parallel with the reply, so the line
  reflects the latest *settled* read — usually the previous turn's.
  That is by design: emotional state is sticky, and per-utterance
  flicker would feel erratic.
- **Realtime**: the seed guidance (above) is the steering; the model's
  native affective dialogue supplies the prosody read.

### (b) Voice delivery per TTS leg

- **Cartesia Sonic (cascade, when selected):** real control.
  `agent._apply_cartesia_emotion` calls the plugin's documented
  `update_options(emotion=[...], speed=...)` after each read, so
  subsequent replies are synthesised with the new delivery. Verified in
  the installed `livekit-plugins-cartesia==1.8.9` source: for sonic-3
  models the plugin sends `generation_config.emotion = emotion[0]`
  (a single Cartesia emotion string) and `generation_config.speed`
  (float, 0.6–1.5). Mapping (`emotion.cartesia_delivery`):

  | User state | Cartesia emotion | Speed | Why |
  |---|---|---|---|
  | upbeat | Content → Excited (high) | 1.0–1.08 | meet the energy |
  | playful | Happy → Excited (high) | 1.0–1.08 | play back |
  | frustrated | Calm | 0.92–0.98 | de-escalate, never mirror |
  | sad | Sympathetic | 0.90–0.97 | soften, slow down |
  | anxious | Calm → Serene (high) | 0.92–0.97 | steady |
  | tired | Peaceful | 0.90–0.97 | low-energy, gentle |
  | neutral | *(unset — no call)* | — | Sonic infers from reply text by default, which is the desired neutral behaviour |
  | distress | Sympathetic | 0.90 | care, regardless of label |

  Before this change `_build_cartesia_tts` passed only
  model/api_key/voice/language — no emotion at all (verified).
- **Every other TTS leg (Inworld/Fish/Rime/… via LiveKit Inference):**
  no emotion control exists on `inference.TTS` as we construct it.
  Delivery is shaped *through the reply text itself* — the brain, under
  the guidance + context line, writes shorter/softer/brighter text and
  Sonic-style inference (and the other expressive TTS models' own text
  inference) follows the words. Documented limitation, not a silent
  gap.
- **Realtime:** delivery is the model's own native-audio prosody (§1b);
  there is no TTS leg to parameterise.

## 3. Safety / care rails

- `distress=true` (self-harm / crisis signals in the read) **overrides
  matching everywhere**: the context line becomes the CARE directive
  (calm, warm, present; take it seriously; gently point to real-world
  help — US 988 Suicide and Crisis Lifeline), the guidance block carries
  the same rule for text/realtime, and Cartesia delivery is forced to
  Sympathetic @ 0.9 whatever the label said. Anger/frustration are never
  mirrored back in content or in voice (mapping above).
- The read is **session-scoped and in-memory only**; no emotion data is
  written to Firestore, the profile, or the token ledger. **Open
  founder question (not decided here):** should a *long-term* emotional
  picture ever be stored (e.g. "user has been low lately" in the wiki)?
  Potential value for continuity of care; real privacy sensitivity.
  Recommendation: keep session-only until the founder decides.
- Fail-soft throughout: an unparseable read degrades to neutral
  (`emotion.normalize_read`), a flag-read failure resolves OFF, and any
  exception in the emotion wiring is logged and swallowed — a call or
  chat must never break because of this feature.

## 4. Cost / latency

- **Voice:** the read rides the voice-actions pass that already runs
  once per finalized turn (same `inference_llm.complete` call, same
  `CONFIG.inference_json_model`); the schema gains 3 fields and the
  guidance a short section — a few dozen extra output tokens on a call
  that already exists, metered to the same voice ledger entry. No new
  call, no sequential step: the pass already runs in parallel with the
  conversation (`relay_voice_commands._run_skill_first` is a task), and
  the TTS `update_options` is a local setter — the next synthesis picks
  it up. **Zero added gateway calls, zero added round trips.**
- **Text:** the read is folded into reply generation itself (guidance
  block in the system prompt). Prompt grows by ~120 tokens/turn,
  partially offset by stable-prefix caching; no extra call.
- **Realtime:** seed grows by the same guidance block (seeded once per
  call); no extra call.
- All inference stays on LiveKit (the voice-actions pass is
  LiveKit-Inference, as before). Gemini remains the production default
  brain. Nothing here touches a direct provider.

## What shipped (staging)

- `functions/bootstrap/emotion.py` — labels, `EmotionRead`,
  `EmotionState` (decay), guidance block, context line, Cartesia
  mapping. Pure, no LiveKit imports.
- `functions/bootstrap/skills/voice_actions.py` + `prompts/voice_actions.md`
  — schema/guidance/verdict carry the read on the existing pass.
- `functions/bootstrap/main.py` — guidance appended in `_prepare_chat`
  (text) and the voice-seed composition (both voice paths), flag-gated
  via `_emotion_matching_enabled`.
- `functions/bootstrap/async_voice.py` — same guidance for async voice
  message replies.
- `functions/bootstrap/agent.py` — cascade wiring: `relay_voice_commands`
  `on_emotion` callback → `EmotionState` → `_apply_cartesia_emotion`
  (plugin `update_options`) + `_EmotionAgent.on_user_turn_completed`
  context injection. Realtime path: no code change (see §1b verdict).
- `feature_flags.py` registry + `scripts/feature_flags.seed.json` +
  `docs/FEATURE_FLAGS.md` — `emotion_matching`, default OFF.
- `functions/bootstrap/tests/test_emotion.py` — unit coverage for the
  mapping (values validated against the plugin's emotion literals),
  state decay, distress override, schema fold-in, flag default.

To enable on staging after deploy:
`python3 scripts/flags.py set emotion_matching=true --yes`
(against the staging project) or `FLAG_EMOTION_MATCHING=1` on the
staging services. Scout verifies with the companion test script.
