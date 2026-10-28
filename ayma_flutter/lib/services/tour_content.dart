import 'package:flutter/material.dart';

/// The single, maintainable source of truth for the feature tour (§11.2).
///
/// The tour is modelled as an ordered list of [TourFeature] entries, each with
/// a STABLE [TourFeature.featureId]. That id is what the per-user seen-state
/// tracks (`users/{uid}/profile/main.seen_tour_features`, via
/// [FeatureTourStore]): the first-run walkthrough marks every current id seen,
/// and when a later build ships a NEW entry (a new id the user hasn't seen),
/// the app spotlights only that one on next open.
///
/// Adding a feature to the tour = adding one entry here (new id + short how-to).
/// This is the ONLY place tour copy and ordering live — the screen and the
/// gating logic both read this list. Keep copy short: a guided walkthrough, not
/// documentation.
///
/// Process rule (see docs/AGENT_HANDOFF.md / ARCHITECTURE §11.2): every new
/// user-facing feature must add/update its entry in this list (feature_id +
/// how-to) as part of its definition of done.
///
/// Ids are permanent: renaming an id re-shows that feature to everyone, so pick
/// a stable snake_case name and never reuse it for something else.
class TourFeature {
  const TourFeature({
    required this.featureId,
    required this.headline,
    required this.subtitle,
    required this.visual,
    this.icon,
  });

  /// Stable key persisted in `seen_tour_features`. Never reuse or rename.
  final String featureId;

  final String headline;

  /// One short line — how to use it, not a spec.
  final String subtitle;

  /// Which illustration the card shows. [TourVisual.icon] uses [icon].
  final TourVisual visual;

  /// The glyph for [TourVisual.icon] entries (ignored otherwise).
  final IconData? icon;
}

/// The illustration for a tour card. The first five are bespoke animated demos
/// (see `feature_tour_screen.dart`); [icon] is the generic glyph a new feature
/// can use without authoring a custom animation.
enum TourVisual { orb, profileFill, chatBubbles, coachChips, shield, icon }

/// The ordered tour. Order here is the order pages appear in the first-run
/// walkthrough; new-feature spotlights preserve this relative order too.
const List<TourFeature> tourFeatures = <TourFeature>[
  TourFeature(
    featureId: 'voice_dating',
    headline: 'Dating, by voice',
    subtitle: 'Meet Ayma. Talk to her like a friend — no endless swiping.',
    visual: TourVisual.orb,
  ),
  TourFeature(
    featureId: 'profile_building',
    headline: 'She gets to know you',
    subtitle: 'Just talk. Ayma builds your profile as you chat.',
    visual: TourVisual.profileFill,
  ),
  TourFeature(
    featureId: 'your_story',
    headline: 'Your Story, in your words',
    subtitle:
        'Everything Ayma learns lives in your Story — read it, edit it, anytime.',
    visual: TourVisual.icon,
    icon: Icons.auto_stories_outlined,
  ),
  TourFeature(
    featureId: 'ayma_models',
    headline: 'Ayma, your way',
    subtitle: "Choose Ayma's brain and her voice in Ayma's models settings.",
    visual: TourVisual.icon,
    icon: Icons.tune_rounded,
  ),
  TourFeature(
    featureId: 'appearance_report',
    headline: 'An honest mirror',
    subtitle: 'Get a private, candid read on your photos — only you see it.',
    visual: TourVisual.icon,
    icon: Icons.face_retouching_natural_outlined,
  ),
  TourFeature(
    featureId: 'qloo_taste',
    headline: 'Matched on taste',
    subtitle: 'Qloo pairs you by real taste — music, food, film — not just looks.',
    visual: TourVisual.icon,
    icon: Icons.interests_outlined,
  ),
  TourFeature(
    featureId: 'date_sim',
    headline: 'Practice before you meet',
    subtitle:
        'Rehearse the date — text or voice — with a simulation of your match.',
    visual: TourVisual.chatBubbles,
  ),
  TourFeature(
    featureId: 'chat_coach',
    headline: 'Your wingman in every chat',
    subtitle:
        'Stuck for words? Ayma opens for you and coaches you line by line.',
    visual: TourVisual.coachChips,
  ),
  TourFeature(
    featureId: 'connect_agent',
    headline: 'Bring your own agent',
    subtitle: 'Connect an AI agent to talk to Ayma for you — on your terms.',
    visual: TourVisual.icon,
    icon: Icons.hub_outlined,
  ),
  TourFeature(
    featureId: 'notifications',
    headline: 'Never miss a moment',
    subtitle: "Ayma nudges you only when there's something worth your time.",
    visual: TourVisual.icon,
    icon: Icons.notifications_active_outlined,
  ),
  TourFeature(
    featureId: 'privacy',
    headline: 'Yours, and only yours',
    subtitle: "18+, consent-first, private. You're always in control.",
    visual: TourVisual.shield,
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

/// Decides the auto-show behaviour (§11.2) from a user's seen `feature_id`s:
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
