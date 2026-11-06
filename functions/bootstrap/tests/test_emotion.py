"""Emotion-matched responses (founder directive, 2026-11-06).

Covers the pure layer (``emotion.py``), the fold-in into the voice-actions
skill's single pass (schema + verdict parsing — no extra model call), and
the feature-flag registration. The live behaviour (Scout hearing the
delivery change) is covered by the Scout script in the goal files.
"""

import emotion
import feature_flags
from skills import voice_actions


# --- normalize_read ---------------------------------------------------------


def test_normalize_read_accepts_known_labels():
    read = emotion.normalize_read("Frustrated", "HIGH", False)
    assert read.label == "frustrated"
    assert read.intensity == "high"
    assert read.distress is False


def test_normalize_read_degrades_unknown_to_neutral():
    read = emotion.normalize_read("furious", "extreme", False)
    assert read.label == "neutral"
    assert read.intensity == "low"


def test_normalize_read_defaults_intensity_for_labelled_read():
    read = emotion.normalize_read("sad", "", False)
    assert read.label == "sad"
    assert read.intensity == "medium"


def test_normalize_read_distress_string_forms():
    assert emotion.normalize_read("neutral", "low", "true").distress is True
    assert emotion.normalize_read("neutral", "low", "false").distress is False
    assert emotion.normalize_read("neutral", "low", 1).distress is True


# --- EmotionState ------------------------------------------------------------


def test_state_starts_neutral_and_inactive():
    state = emotion.EmotionState()
    assert state.current().label == "neutral"
    assert state.active is False


def test_state_update_and_decay():
    state = emotion.EmotionState()
    state.update(emotion.normalize_read("frustrated", "high"))
    assert state.current().label == "frustrated"
    assert state.active is True
    # Neutral reads let the decay clock run instead of clearing at once.
    for _ in range(emotion.DECAY_TURNS):
        state.update(emotion.EmotionRead())
    assert state.current().label == "frustrated"
    state.update(emotion.EmotionRead())
    assert state.current().label == "neutral"
    assert state.active is False


def test_state_new_read_replaces_old():
    state = emotion.EmotionState()
    state.update(emotion.normalize_read("sad", "medium"))
    state.update(emotion.normalize_read("upbeat", "low"))
    assert state.current().label == "upbeat"


def test_state_distress_lands_immediately():
    state = emotion.EmotionState()
    state.update(emotion.normalize_read("playful", "high"))
    state.update(emotion.normalize_read("neutral", "low", True))
    assert state.current().distress is True
    assert state.active is True


# --- Context injection --------------------------------------------------------


def test_context_line_neutral_is_empty():
    assert emotion.context_line(emotion.EmotionState()) == ""


def test_context_line_names_adjustment_not_detection_script():
    state = emotion.EmotionState()
    state.update(emotion.normalize_read("sad", "medium"))
    line = emotion.context_line(state)
    assert "sad" in line
    assert "never quote it" in line
    assert "silver linings" in line


def test_context_line_distress_is_care_not_matching():
    state = emotion.EmotionState()
    state.update(emotion.normalize_read("upbeat", "high", True))
    line = emotion.context_line(state)
    assert "CARE" in line
    assert "988" in line


def test_guidance_block_covers_labels_and_care():
    block = emotion.guidance_block()
    for word in ("Upbeat", "Playful", "Frustrated", "Sad", "Anxious", "Tired"):
        assert word in block
    assert "988" in block
    assert "never name the detection" in block.lower()


def test_apply_to_prompt_flag_off_is_byte_identical():
    prompt = "base prompt"
    assert emotion.apply_to_prompt(prompt, enabled=False) == prompt
    out = emotion.apply_to_prompt(prompt, enabled=True)
    assert out.startswith(prompt)
    assert "EMOTION MATCHING" in out


# --- Cartesia delivery mapping -------------------------------------------------

# The plugin's TTSVoiceEmotion literals (livekit-plugins-cartesia 1.8.9).
_PLUGIN_EMOTIONS = {
    "Happy", "Excited", "Enthusiastic", "Elated", "Euphoric", "Triumphant",
    "Amazed", "Surprised", "Flirtatious", "Joking/Comedic", "Curious",
    "Content", "Peaceful", "Serene", "Calm", "Grateful", "Affectionate",
    "Trust", "Sympathetic", "Anticipation", "Mysterious", "Angry", "Mad",
    "Outraged", "Frustrated", "Agitated", "Threatened", "Disgusted",
    "Contempt", "Envious", "Sarcastic", "Ironic", "Sad", "Dejected",
    "Melancholic", "Disappointed", "Hurt", "Guilty", "Bored", "Tired",
    "Rejected", "Nostalgic", "Wistful", "Apologetic", "Hesitant",
    "Insecure", "Confused", "Resigned", "Anxious", "Panicked", "Alarmed",
    "Scared", "Neutral", "Proud", "Confident", "Distant", "Skeptical",
    "Contemplative", "Determined",
}


def test_cartesia_delivery_values_are_plugin_valid():
    for label in emotion.LABELS:
        for intensity in emotion.INTENSITIES:
            emo, speed = emotion.cartesia_delivery(
                emotion.normalize_read(label, intensity)
            )
            assert emo is None or emo in _PLUGIN_EMOTIONS
            assert speed is None or 0.6 <= speed <= 1.5


def test_cartesia_delivery_neutral_defers_to_sonic_inference():
    assert emotion.cartesia_delivery(emotion.EmotionRead()) == (None, None)


def test_cartesia_delivery_never_mirrors_negative_emotions():
    # De-escalation, not mirroring: the user's negative state must never
    # come back at them in Ayma's voice.
    for label in ("frustrated", "sad", "anxious"):
        emo, _speed = emotion.cartesia_delivery(
            emotion.normalize_read(label, "high")
        )
        assert emo not in ("Frustrated", "Angry", "Sad", "Anxious")
    emo, speed = emotion.cartesia_delivery(
        emotion.normalize_read("frustrated", "high")
    )
    assert emo == "Calm"
    assert speed < 1.0


def test_cartesia_delivery_distress_overrides_label():
    emo, speed = emotion.cartesia_delivery(
        emotion.normalize_read("playful", "high", True)
    )
    assert emo == "Sympathetic"
    assert speed <= 0.9


# --- Voice-actions fold-in ------------------------------------------------------


def test_voice_actions_schema_carries_emotion_fields():
    props = voice_actions.RESPONSE_SCHEMA["properties"]
    assert set(emotion.LABELS) <= set(props["emotion"]["enum"])
    assert set(emotion.INTENSITIES) <= set(props["emotion_intensity"]["enum"])
    assert props["distress"]["type"] == "boolean"
    # The fold-in must not change the pass's required shape: action only.
    assert voice_actions.RESPONSE_SCHEMA["required"] == ["action"]


def test_parse_verdict_reads_emotion_fields():
    verdict = voice_actions.parse_verdict(
        {
            "action": "none",
            "emotion": "anxious",
            "emotion_intensity": "high",
            "distress": False,
        }
    )
    assert verdict.action == "none"
    assert verdict.emotion.label == "anxious"
    assert verdict.emotion.intensity == "high"
    assert verdict.emotion.distress is False


def test_parse_verdict_without_emotion_fields_stays_neutral():
    verdict = voice_actions.parse_verdict({"action": "navigate", "page": "explore"})
    assert verdict.emotion.label == "neutral"
    assert verdict.emotion.distress is False


def test_parse_verdict_bad_emotion_degrades_to_neutral():
    verdict = voice_actions.parse_verdict(
        {"action": "none", "emotion": "ecstatic", "emotion_intensity": "max"}
    )
    assert verdict.emotion.label == "neutral"


def test_voice_actions_guidance_asks_for_emotion_read():
    guidance = voice_actions.load_guidance()
    assert "emotion" in guidance.lower()
    assert "distress" in guidance.lower()


# --- Feature flag -----------------------------------------------------------------


def test_emotion_matching_flag_registered_default_off():
    flag = feature_flags.REGISTRY["emotion_matching"]
    assert flag.kind == "bool"
    value, _source = feature_flags.resolve("emotion_matching")
    assert value is False


def test_emotion_matching_flag_env_override(monkeypatch):
    monkeypatch.setenv("FLAG_EMOTION_MATCHING", "true")
    value, source = feature_flags.resolve("emotion_matching")
    assert value is True
    assert source == "env"
