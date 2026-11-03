import 'package:flutter/material.dart';

import 'tour_anchors.dart';

/// The single, maintainable source of truth for the feature tour (§11.2a).
///
/// The tour is an INTERACTIVE coach-mark walkthrough: each [TourFeature] names
/// a real UI element ([anchorId]) that the coach-mark engine
/// (`coach_mark_overlay.dart`) spotlights in the live app, with a one-line
/// how-to beside it. The tour is modelled as an ordered list of entries, each
/// with a STABLE [TourFeature.featureId]. That id is what the per-user
/// seen-state tracks (`users/{uid}/profile/main.seen_tour_features`, via
/// [FeatureTourStore]): the first-run walkthrough marks every current id seen,
/// and when a later build ships a NEW entry (a new id the user hasn't seen),
/// the app spotlights only that one on next open.
///
/// Adding a feature to the tour = adding one entry here: a new id, a short
/// how-to, and the [anchorId] (+ [tab]) of the UI element it points at. This is
/// the ONLY place tour copy, ordering and anchors live — the engine and the
/// gating logic both read this list. Keep copy short: a guided walkthrough, not
/// documentation.
///
/// Process rule (see docs/AGENT_HANDOFF.md / ARCHITECTURE §11.2a): every new
/// user-facing feature must add/update its entry here (feature_id + how-to +
/// its UI anchor key) as part of its definition of done.
///
/// Ids are permanent: renaming an id re-shows that feature to everyone, so pick
/// a stable snake_case name and never reuse it for something else.
class TourFeature {
  const TourFeature({
    required this.featureId,
    required this.headline,
    required this.subtitle,
    this.icon,
    this.anchorId,
    this.tab,
  });

  /// Stable key persisted in `seen_tour_features`. Never reuse or rename.
  final String featureId;

  final String headline;

  /// One short line — how to use it, not a spec.
  final String subtitle;

  /// A small glyph shown in the callout (optional).
  final IconData? icon;

  /// The [TourAnchors] id of the UI element to spotlight. Null → a centered
  /// callout with no spotlight (an intro/outro step that points at no single
  /// element). A non-null id that can't be resolved on this build (a gated
  /// feature, a missing widget) makes the step skip gracefully.
  final String? anchorId;

  /// Which shell tab (the `IndexedStack` index: 0 Ayma, 1 Explore, 2 Messages,
  /// 3 Profile) must be the active body for [anchorId] to be laid out. Null for
  /// anchors that live in the always-visible nav bar (orb, tabs, bell) or for
  /// centered steps. The engine switches to this tab before spotlighting.
  final int? tab;
}

/// The ordered tour. Order here is the order elements are spotlighted in the
/// first-run walkthrough; new-feature spotlights preserve this relative order
/// too. Each entry names the real UI anchor it points at (see [TourAnchors]).
const List<TourFeature> tourFeatures = <TourFeature>[
  TourFeature(
    featureId: 'voice_dating',
    headline: 'Dating, by voice',
    subtitle: 'Press and hold the orb to start a voice chat — meet Ayma.',
    icon: Icons.graphic_eq_rounded,
    anchorId: TourAnchors.homeOrb,
  ),
  TourFeature(
    featureId: 'orb_tap_progression',
    headline: 'Tap the orb to go deeper',
    subtitle: 'Tap once for a quick chat about the page you\'re on, tap again '
        'to open it full screen, and tap on the full chat to talk out loud. '
        '(Holding the orb still jumps straight to voice.)',
    icon: Icons.touch_app_outlined,
    anchorId: TourAnchors.homeOrb,
  ),
  TourFeature(
    featureId: 'profile_building',
    headline: 'Or just say hi',
    subtitle: 'Type right here — Ayma builds your profile as you chat.',
    icon: Icons.edit_outlined,
    anchorId: TourAnchors.homeComposer,
    tab: 0,
  ),
  TourFeature(
    featureId: 'ayma_guided_tour',
    headline: 'Let Ayma show you around',
    subtitle: 'Say "walk me through the app" and Ayma gives you a live, guided '
        'tour — she opens each page, highlights what to tap, and waits for you.',
    icon: Icons.tour_outlined,
    anchorId: TourAnchors.homeOrb,
  ),
  // The Profile walkthrough: tap the Profile tab to open it (press-through,
  // §11.2a), then sub-steps spotlight the real rows inside — Story, Appearance
  // and Ayma's settings — top to bottom, each scrolled into view.
  TourFeature(
    featureId: 'profile_hub',
    headline: 'Your profile, your hub',
    subtitle: 'Tap Profile — your story, your look and Ayma all live here.',
    icon: Icons.person_outline_rounded,
    anchorId: TourAnchors.profileTab,
  ),
  TourFeature(
    featureId: 'your_story',
    headline: 'Your Story, in your words',
    subtitle: 'Open My story to read or edit everything Ayma learns about you.',
    icon: Icons.auto_stories_outlined,
    anchorId: TourAnchors.profileStoryRow,
    tab: 3,
  ),
  TourFeature(
    featureId: 'appearance_report',
    headline: 'An honest mirror',
    subtitle: 'Open Appearance, tick several photos per section, and get one '
        'private, candid read across them all.',
    icon: Icons.face_retouching_natural_outlined,
    anchorId: TourAnchors.profileAppearanceRow,
    tab: 3,
  ),
  TourFeature(
    featureId: 'ayma_models',
    headline: 'Ayma, your way',
    subtitle: "Open Ayma's settings to choose her brain and her voice.",
    icon: Icons.tune_rounded,
    anchorId: TourAnchors.profileAymaSettingsRow,
    tab: 3,
  ),
  TourFeature(
    featureId: 'ask_ayma_change_models',
    headline: 'Just ask her to switch',
    subtitle: 'Tell Ayma "switch your brain to Muse", "use cascade mode", '
        '"use Deepgram for speech-to-text", "use Inworld for text-to-speech" '
        'or "use the Kore voice" — in chat or on a call. She saves it; say '
        '"reconnect" to apply it to the call right now.',
    icon: Icons.sync_alt_rounded,
    anchorId: TourAnchors.profileAymaSettingsRow,
    tab: 3,
  ),
  TourFeature(
    featureId: 'qloo_taste',
    headline: 'Matched on taste',
    subtitle: 'Tap Explore — Qloo pairs you by real taste, not just looks.',
    icon: Icons.interests_outlined,
    anchorId: TourAnchors.exploreTab,
  ),
  TourFeature(
    featureId: 'date_sim',
    headline: 'Practice before you meet',
    subtitle: 'In Explore, open a profile and tap ✨ to watch your AIs feel '
        'each other out and see the score. Tap ✨ again any time to reopen '
        'that result and keep the conversation going.',
    icon: Icons.chat_bubble_outline_rounded,
    anchorId: TourAnchors.exploreTab,
  ),
  TourFeature(
    featureId: 'sim_controls',
    headline: 'Run the sim your way',
    subtitle: 'In a simulated date you can stop it mid-conversation, choose how '
        'many more messages to add when you keep it going, or start over fresh.',
    icon: Icons.tune_rounded,
    anchorId: TourAnchors.exploreTab,
  ),
  TourFeature(
    featureId: 'chat_coach',
    headline: 'Your wingman in every chat',
    subtitle: "Stuck for words? In Messages, Ayma coaches you line by line.",
    icon: Icons.forum_outlined,
    anchorId: TourAnchors.messagesTab,
  ),
  TourFeature(
    featureId: 'dm_media',
    headline: 'Photos & GIFs in chat',
    subtitle: 'In a chat, tap + to send a photo — or your keyboard\'s GIF '
        'button to send a GIF.',
    icon: Icons.gif_box_outlined,
    anchorId: TourAnchors.messagesTab,
  ),
  TourFeature(
    featureId: 'connect_agent',
    headline: 'Bring your own agent',
    subtitle: 'Connect an AI agent to talk to Ayma for you — set it up in Settings.',
    icon: Icons.hub_outlined,
  ),
  TourFeature(
    featureId: 'notifications',
    headline: 'Never miss a moment',
    subtitle: "The bell nudges you only when there's something worth your "
        'time — choose what from Settings › Notifications.',
    icon: Icons.notifications_active_outlined,
    anchorId: TourAnchors.notificationsBell,
  ),
  TourFeature(
    featureId: 'privacy',
    headline: 'Yours, and only yours',
    subtitle: "18+, consent-first, private. You're always in control.",
    icon: Icons.shield_outlined,
  ),
];

/// Every current tour feature id — what the first-run walkthrough marks seen.
Set<String> allTourFeatureIds() =>
    tourFeatures.map((f) => f.featureId).toSet();

/// What the auto-show gate should do, given the user's seen set.
class TourGateDecision {
  const TourGateDecision({
    required this.show,
    required this.spotlight,
    required this.features,
  });

  /// Whether to auto-show the tour at all.
  final bool show;

  /// New-feature spotlight (returning user, some ids unseen) vs the full
  /// first-run walkthrough.
  final bool spotlight;

  /// The features to show, in tour order. Empty when [show] is false.
  final List<TourFeature> features;
}

/// Decides the auto-show behaviour (§11.2a) from a user's seen `feature_id`s:
///  * nothing seen  → first run: the FULL walkthrough, not a spotlight.
///  * some seen, some current ids missing → a SPOTLIGHT of only the unseen
///    (new) features, in tour order.
///  * every current id seen → show nothing.
///
/// Pure — no I/O — so the gate's logic is unit-testable on its own. [all]
/// defaults to the live [tourFeatures]; tests pass a fixed list.
TourGateDecision decideTour(
  Set<String> seen, {
  List<TourFeature> all = tourFeatures,
}) {
  final unseen = all.where((f) => !seen.contains(f.featureId)).toList();
  if (unseen.isEmpty) {
    return const TourGateDecision(show: false, spotlight: false, features: []);
  }
  final firstRun = seen.isEmpty;
  return TourGateDecision(
    show: true,
    spotlight: !firstRun,
    features: firstRun ? all : unseen,
  );
}
