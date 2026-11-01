/// The legal/consent intents the sign-in page's greeting voice can act on
/// locally (§3.3).
///
/// The pre-sign-in greeting is a backend LiveKit agent reached via
/// `POST /welcome/token` with NO account, so the normal Ayma-driven
/// navigation path ([AppCommandService]) is dead here: it watches
/// `users/{uid}/app_commands/pending`, and there is no uid before sign-in.
/// The one thing the app DOES get from the welcome room is the live
/// transcript, so these intents are recognised app-side off the user's own
/// finalized voice turns and handled with the same in-app navigation the
/// clickwrap links already use.
enum SignInVoiceIntent {
  /// Nothing legal/consent-related to act on.
  none,

  /// Open the Terms & Conditions screen.
  openTerms,

  /// Open the Privacy Policy screen.
  openPrivacy,

  /// Open the Biometric Information screen.
  openBiometric,

  /// Tell the user the critical consent items before they sign in.
  critical,
}

/// Verbs that signal the user wants a legal document opened, not merely
/// mentioned. Requiring one keeps a passing reference ("I agree to the terms")
/// from navigating; an explicit ask ("open the terms", "show me the privacy
/// policy", "where's the biometric info") does.
const List<String> _openCues = [
  'open',
  'show',
  'see',
  'read',
  'view',
  'display',
  'pull up',
  'bring up',
  'take me to',
  'go to',
  'where is',
  'where are',
  "where's",
  'link to',
  'can i see',
  'let me see',
];

/// Phrases that mean "tell me the important things I need to know".
const List<String> _criticalCues = [
  'critical',
  'aware',
  'important',
  'should i know',
  'should i be',
  'anything i should',
  'what should i know',
  'need to know',
  'watch out',
  'heads up',
  'gotcha',
];

/// Classify one finalized user utterance from the sign-in greeting. Returns
/// the single intent to act on, or [SignInVoiceIntent.none].
///
/// Navigation intents require both a document keyword and an "open" cue; when
/// more than one document is named, the earliest-mentioned one wins (so "open
/// the terms and the privacy policy" opens Terms). A "what's critical" ask
/// needs no document keyword.
SignInVoiceIntent parseSignInVoiceIntent(String utterance) {
  final text = utterance.toLowerCase();
  if (text.trim().isEmpty) return SignInVoiceIntent.none;

  final wantsOpen = _openCues.any(text.contains);
  if (wantsOpen) {
    // Earliest-mentioned document wins. `biometric`/`face` is checked as its
    // own group so "face matching" / "face recognition" map to the biometric
    // screen even though they don't contain the word "biometric".
    final candidates = <SignInVoiceIntent, int>{};
    void note(SignInVoiceIntent intent, Iterable<String> keywords) {
      for (final k in keywords) {
        final i = text.indexOf(k);
        if (i != -1) {
          candidates[intent] = candidates.containsKey(intent)
              ? (i < candidates[intent]! ? i : candidates[intent]!)
              : i;
        }
      }
    }

    note(SignInVoiceIntent.openBiometric,
        const ['biometric', 'face recognition', 'face match', 'face data']);
    note(SignInVoiceIntent.openPrivacy, const ['privacy']);
    note(SignInVoiceIntent.openTerms,
        const ['terms', 'conditions', 'terms of service']);

    if (candidates.isNotEmpty) {
      return candidates.entries
          .reduce((a, b) => a.value <= b.value ? a : b)
          .key;
    }
  }

  if (_criticalCues.any(text.contains)) return SignInVoiceIntent.critical;
  return SignInVoiceIntent.none;
}
