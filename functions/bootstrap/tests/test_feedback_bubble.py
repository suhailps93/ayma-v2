"""Feedback bubble decisions (feedback_bubble.py): explicit trigger,
frustration rule, once-per-session-per-trigger cap."""

import feedback_bubble as fb


def _decide(message="", tools=(), **kw):
    gate = fb.FeedbackBubbleGate()
    return fb.decide_feedback_bubble(
        uid="u1", session_id="s1", message=message, tools_used=tools,
        gate=gate, **kw,
    )


def test_explicit_variants_trigger():
    for text in (
        "capture feedback",
        "Capture feedback please",
        "please capture my feedback",
        "record feedback",
        "submit feedback",
        "I want to give feedback",
        "I have some feedback",
        "leave feedback",
        "take my feedback",
    ):
        out = _decide(text)
        assert out is not None and out["trigger"] == "explicit", text


def test_explicit_prefill_extracted():
    out = _decide("capture feedback: the mic keeps dropping my call")
    assert out["prefill"] == "the mic keeps dropping my call"
    out = _decide("capture feedback")
    assert out["prefill"] == ""


def test_plain_feedback_mention_does_not_trigger():
    for text in (
        "thanks for the feedback",
        "that feedback was helpful",
        "what did my matches think? any feedback?",
        "hello, how are you",
        "",
    ):
        assert _decide(text) is None, text


def test_frustration_via_record_feedback_tool():
    out = _decide("ok whatever", tools=["Noted your feedback"])
    assert out is not None and out["trigger"] == "frustration"


def test_frustration_via_lexical_signal():
    for text in (
        "you keep asking me the same thing",
        "that is not what I said",
        "you are not listening to me",
        "stop repeating yourself",
    ):
        out = _decide(text)
        assert out is not None and out["trigger"] == "frustration", text


def test_frustration_via_emotion_read():
    out = _decide("hm", emotion_label="frustrated", emotion_intensity="high")
    assert out is not None and out["trigger"] == "frustration"
    # Low-intensity frustration is not enough on the emotion signal alone.
    assert _decide("hm", emotion_label="frustrated",
                   emotion_intensity="low") is None
    # Other emotions never offer a bubble.
    assert _decide("hm", emotion_label="sad", emotion_intensity="high") is None


def test_distress_suppresses_frustration_offer():
    out = _decide("you keep asking", distress=True)
    assert out is None


def test_draft_card_suppresses_bubble():
    assert _decide("capture feedback", has_draft_card=True) is None
    assert _decide("you keep asking", tools=["Noted your feedback"],
                   has_draft_card=True) is None


def test_once_per_session_per_trigger():
    gate = fb.FeedbackBubbleGate()
    kw = dict(uid="u1", session_id="s1", gate=gate)
    first = fb.decide_feedback_bubble(message="capture feedback", **kw)
    assert first is not None
    # Same trigger again in the same session: capped.
    assert fb.decide_feedback_bubble(message="capture feedback", **kw) is None
    # The other trigger still gets its one offer.
    other = fb.decide_feedback_bubble(
        message="you keep asking", tools_used=["Noted your feedback"], **kw)
    assert other is not None and other["trigger"] == "frustration"
    assert fb.decide_feedback_bubble(
        message="you keep asking", tools_used=["Noted your feedback"], **kw) is None
    # A different session is a fresh cap.
    fresh = fb.decide_feedback_bubble(
        uid="u1", session_id="s2", message="capture feedback", gate=gate)
    assert fresh is not None
