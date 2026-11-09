import 'package:flutter/foundation.dart';

import 'tour_content.dart';

/// One step of the Ayma-DRIVEN interactive tour (§11.2b), pushed from the
/// backend (`skills/guided_tour.py`) one at a time as a `tour_step` app-command
/// and rendered by the root [TourHost] through the shared [CoachMarkOverlay].
///
/// Unlike the passive tour (a local `List<TourFeature>` the overlay walks on
/// its own), each driven step is a single [feature] plus callbacks that report
/// back to [AppCommandService] so the backend can ack it and wait for the
/// user before sending the next step:
///  * [onShown]   — the spotlight is up (ack `ok:true`);
///  * [onAbsent]  — the anchor isn't on this build (ack `ok:false` → backend
///                  skips the step honestly);
///  * [onTapped]  — the user tapped the highlight: for a step with a
///                  command nothing (Ayma performs it herself when the step
///                  is shown; a tap only retries a failed attempt), and a
///                  step with nothing to perform completes;
///  * [onSkip]    — the user pressed Next on the card (the go after a
///                  performed step, or a move on without performing it;
///                  optional — steps built outside the service may omit it);
///  * [onStop]    — the user pressed "Skip tour" (the whole tour ends).
@immutable
class GuidedTourStep {
  const GuidedTourStep({
    required this.token,
    required this.feature,
    required this.index,
    required this.total,
    required this.onShown,
    required this.onAbsent,
    required this.onTapped,
    required this.onStop,
    this.onSkip,
    this.performed = false,
    this.explainer = false,
  });

  /// A per-command id; the overlay is keyed by it so every pushed step gets a
  /// fresh measure (and so [onShown] fires once for each one).
  final String token;

  /// The single spotlighted step, built from the backend command.
  final TourFeature feature;

  /// 0-based position and total, for the "N of M" callout counter.
  final int index;
  final int total;

  final VoidCallback onShown;
  final VoidCallback onAbsent;
  final VoidCallback onTapped;
  final VoidCallback onStop;
  final VoidCallback? onSkip;

  /// The step's command ran and is confirmed: the highlight is gone so the
  /// user can look at what opened, and the tour waits for their go.
  final bool performed;

  /// A §11.2c page-explainer step (look-only highlighting), as opposed to a
  /// real driven-tour step. The two share this overlay path, but render
  /// differently: an explainer keeps its callout card (it stays exactly as
  /// built), while a driven-tour step is chromeless — no card at all, just the
  /// spotlight, since Ayma announces it in her own voice/chat line (founder,
  /// 2026-11-08). [TourHost] reads this to pick the rendering.
  final bool explainer;

  /// This step with [notice] as its card line, keeping the token so the
  /// overlay stays up instead of re-measuring.
  GuidedTourStep withOutcome({required bool performed, required String notice}) {
    return GuidedTourStep(
      token: token,
      feature: TourFeature(
        featureId: feature.featureId,
        headline: feature.headline,
        subtitle: notice,
        icon: feature.icon,
        anchorId: feature.anchorId,
        tab: feature.tab,
        typingAllowed: feature.typingAllowed,
      ),
      index: index,
      total: total,
      onShown: onShown,
      onAbsent: onAbsent,
      onTapped: onTapped,
      onStop: onStop,
      onSkip: onSkip,
      performed: performed,
      explainer: explainer,
    );
  }
}

/// App-wide controller for the Ayma-driven tour's current step. A singleton like
/// [TourController] / [TabRequest]: [AppCommandService] drives it from
/// `tour_step` / `tour_end` commands, the root [TourHost] renders it (ABOVE the
/// passive tour, so the two never stack). Holds exactly one step at a time;
/// [show] replaces it, [dismiss] clears it.
class GuidedTourController extends ChangeNotifier {
  GuidedTourController._();

  static final GuidedTourController instance = GuidedTourController._();

  GuidedTourStep? _step;
  bool _sessionActive = false;
  bool _voiceOnly = false;

  /// The step currently being spotlighted, or null when no driven tour step is
  /// up (including the brief gap between a tap and the next step).
  GuidedTourStep? get step => _step;

  /// Whether a driven tour step is currently showing.
  bool get active => _step != null;

  /// Whether a driven tour SESSION is running — true from the first step until
  /// the tour ends (`endSession`), even in the gap between steps. `TourHost`
  /// uses this to suppress the passive coach-mark tour for the whole session,
  /// so it can never flash over a different anchor between driven steps
  /// (founder, 2026-11-03: "it is not highlighting the right one").
  bool get sessionActive => _sessionActive;

  /// Whether a live voice call is running, so the user's go is spoken only:
  /// the card hides Next and a tap never counts as the go (a tap near the
  /// orb can disconnect Ayma, founder 2026-11-08).
  bool get voiceOnly => _voiceOnly;

  /// Whether the step with [token] is still the one showing.
  bool isShowing(String token) => _step?.token == token;

  /// Show (or replace) the current driven step and mark the session active.
  void show(GuidedTourStep step, {bool voiceOnly = false}) {
    _step = step;
    _sessionActive = true;
    _voiceOnly = voiceOnly;
    notifyListeners();
  }

  /// A call started or ended mid-step: the showing step follows it at once,
  /// so a call that drops never leaves the user without Next.
  void setVoiceOnly(bool voiceOnly) {
    if (_voiceOnly == voiceOnly) return;
    _voiceOnly = voiceOnly;
    notifyListeners();
  }

  /// Record the outcome of the showing step's command: [performed] takes the
  /// highlight down and waits for the go; otherwise the highlight stays so
  /// the user can tap again. [notice] replaces the card line either way. A
  /// no-op when [token] is no longer the step showing.
  void recordOutcome(
    String token, {
    required bool performed,
    required String notice,
  }) {
    final step = _step;
    if (step == null || step.token != token) return;
    _step = step.withOutcome(performed: performed, notice: notice);
    notifyListeners();
  }

  /// Clear the current step's spotlight (the user tapped it / the anchor was
  /// absent) WITHOUT ending the session — the backend will send the next step.
  /// A no-op when nothing is showing.
  void clearStep() {
    if (_step == null) return;
    _step = null;
    notifyListeners();
  }

  /// End the whole driven tour session: clear the step and let the passive tour
  /// resume its normal gating. The `tour_end` command and the "Skip tour"
  /// affordance both call this.
  void endSession() {
    if (_step == null && !_sessionActive) return;
    _step = null;
    _sessionActive = false;
    notifyListeners();
  }

  /// Back pressed while the driven tour is up (see `MainShellScreen`'s
  /// `PopScope`): run the showing step's stop — the same callback the tiny
  /// "Skip tour" fires, which reports the 'stop' event the backend's
  /// `advance_guided_tour` is polling for — and end the session. Between
  /// steps (session alive, no step showing) there is nothing to signal, so it
  /// just ends the session.
  void stopFromBack() {
    final step = _step;
    if (step == null) {
      endSession();
      return;
    }
    step.onStop();
  }
}
