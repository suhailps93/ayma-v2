/// In-chat feedback bubble triggers (founder spec, 2026-11-06).
///
/// The bubble is a card rendered inside the chat stream that asks the
/// user what their feedback is. Two triggers, mirroring the server rule
/// in `functions/bootstrap/feedback_bubble.py`:
///
/// * explicit — the user says/types "capture feedback" (or a close
///   variant). Deterministic string matching, never the model's
///   discretion, so it works identically for typed turns and finalized
///   voice transcripts landing in the same [TranscriptStore].
/// * frustration — Ayma slipped / the user is frustrated with Ayma.
///   The server signals its strong form (Ayma's own `record_feedback`
///   fired) via the reply's `feedback_bubble` payload; client-side, a
///   conservative lexical read of the user's own finalized turns covers
///   voice turns and any turn the server hint misses. The patterns are
///   deliberately narrow (second person + a failure) — false-positive
///   nagging is the failure mode to avoid.
///
/// Each trigger is offered at most once per chat session
/// ([FeedbackBubbleGate]); dismissing or sending does not re-arm it.
library;

/// Why a feedback bubble is being offered.
enum FeedbackBubbleTrigger { explicit, frustration }

/// A bubble offer: which trigger fired, plus any feedback text the user
/// already stated alongside the trigger (prefilled into the card).
class FeedbackBubbleRequest {
  const FeedbackBubbleRequest({required this.trigger, this.prefill = ''});

  final FeedbackBubbleTrigger trigger;
  final String prefill;
}

final _explicitPatterns = <RegExp>[
  RegExp(r'\bcapture\s+(?:my\s+|some\s+|this\s+)?feedback\b',
      caseSensitive: false),
  RegExp(r'\brecord\s+(?:my\s+|some\s+|this\s+)?feedback\b',
      caseSensitive: false),
  RegExp(r'\btake\s+(?:my\s+|some\s+|this\s+)?feedback\b',
      caseSensitive: false),
  RegExp(r'\blog\s+(?:my\s+|some\s+|this\s+)?feedback\b',
      caseSensitive: false),
  RegExp(r'\bsubmit\s+(?:my\s+|some\s+|this\s+)?feedback\b',
      caseSensitive: false),
  RegExp(r'\bfeedback\s+capture\b', caseSensitive: false),
  RegExp(
      r'\bi\s+(?:want|would\s+like|need)\s+to\s+(?:give|leave|submit|share)\s+(?:some\s+|my\s+)?feedback\b',
      caseSensitive: false),
  RegExp(r'\bi\s+have\s+(?:some\s+)?feedback\b', caseSensitive: false),
  RegExp(r'\bgive\s+feedback\b', caseSensitive: false),
  RegExp(r'\bleave\s+feedback\b', caseSensitive: false),
];

/// True when the user plainly asked to capture/give feedback. A bare
/// mention of the word "feedback" is NOT enough.
bool isExplicitFeedbackRequest(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  return _explicitPatterns.any((p) => p.hasMatch(t));
}

/// Feedback content stated alongside the trigger phrase, e.g.
/// "capture feedback: the mic keeps dropping" -> "the mic keeps
/// dropping". Empty when the message was just the trigger.
String extractFeedbackPrefill(String text) {
  final t = text.trim();
  for (final p in _explicitPatterns) {
    final m = p.firstMatch(t);
    if (m != null) {
      var rest = t.substring(m.end).trim();
      rest = rest.replaceFirst(RegExp(r'^[:\-\u2014]+\s*'), '').trim();
      if (rest.isEmpty || rest.toLowerCase() == 'please' ||
          rest.toLowerCase() == 'now' || rest.toLowerCase() == 'please now') {
        return '';
      }
      return rest.length > 4000 ? rest.substring(0, 4000) : rest;
    }
  }
  return '';
}

final _frustrationPatterns = <RegExp>[
  RegExp(r'\byou\s+keep\s+(asking|saying|repeating|doing)',
      caseSensitive: false),
  RegExp(r'\byou\s+(already|just)\s+asked', caseSensitive: false),
  RegExp(r'\byou\s+are\s+not\s+listening', caseSensitive: false),
  RegExp(r"\byou\s+aren'?t\s+listening", caseSensitive: false),
  RegExp(r'\bnot\s+what\s+i\s+(said|asked|meant)', caseSensitive: false),
  RegExp(r"\bthat'?s\s+not\s+what\s+i\s+(said|asked|meant)",
      caseSensitive: false),
  RegExp(r'\bstop\s+repeating', caseSensitive: false),
  RegExp(r'\byou\s+got\s+(it|that)\s+wrong', caseSensitive: false),
  RegExp(r'\bwrong\s+again\b', caseSensitive: false),
  RegExp(r'\byou\s+messed\s+up', caseSensitive: false),
  RegExp(r'\bthis\s+is\s+frustrating\b', caseSensitive: false),
  RegExp(r"\bi'?m\s+frustrated\b", caseSensitive: false),
  RegExp(r'\bso\s+annoying\b', caseSensitive: false),
  RegExp(r'\byou\s+ignored\s+(my|what)', caseSensitive: false),
  RegExp(r"\bdidn'?t\s+listen\b", caseSensitive: false),
];

/// Conservative lexical read: frustration aimed at Ayma's conduct.
bool looksFrustratedWithAyma(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  return _frustrationPatterns.any((p) => p.hasMatch(t));
}

/// Once-per-session-per-trigger cap for bubble offers. One gate per
/// chat session (the ChatScreen's lifetime).
class FeedbackBubbleGate {
  final _shown = <FeedbackBubbleTrigger>{};

  /// True (and records the offer) iff this trigger has not been
  /// offered yet this session.
  bool claim(FeedbackBubbleTrigger trigger) => _shown.add(trigger);

  bool hasShown(FeedbackBubbleTrigger trigger) => _shown.contains(trigger);
}

/// Evaluate one finalized user turn (typed or voice) for a bubble
/// offer. Explicit wins over frustration; the gate enforces the cap.
FeedbackBubbleRequest? evaluateUserTurnForBubble(
  String text,
  FeedbackBubbleGate gate,
) {
  if (isExplicitFeedbackRequest(text)) {
    if (gate.claim(FeedbackBubbleTrigger.explicit)) {
      return FeedbackBubbleRequest(
        trigger: FeedbackBubbleTrigger.explicit,
        prefill: extractFeedbackPrefill(text),
      );
    }
    return null;
  }
  if (looksFrustratedWithAyma(text)) {
    if (gate.claim(FeedbackBubbleTrigger.frustration)) {
      return const FeedbackBubbleRequest(
          trigger: FeedbackBubbleTrigger.frustration);
    }
  }
  return null;
}

/// A server `feedback_bubble` payload (`{"trigger": ..., "prefill":
/// ...}`) as a request, claimed through the same gate so a server hint
/// and a client detection can never double-offer one trigger.
FeedbackBubbleRequest? requestFromServerPayload(
  Map<String, dynamic>? payload,
  FeedbackBubbleGate gate,
) {
  if (payload == null) return null;
  final trigger = switch (payload['trigger']) {
    'explicit' => FeedbackBubbleTrigger.explicit,
    'frustration' => FeedbackBubbleTrigger.frustration,
    _ => null,
  };
  if (trigger == null) return null;
  if (!gate.claim(trigger)) return null;
  return FeedbackBubbleRequest(
    trigger: trigger,
    prefill: (payload['prefill'] as String? ?? '').trim(),
  );
}
