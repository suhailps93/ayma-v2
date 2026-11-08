import 'package:flutter/widgets.dart';

/// The bridge between the data-only feature tour ([tourFeatures]) and the real
/// UI it spotlights (§11.2a). Every tour target widget attaches a stable
/// [GlobalKey] obtained from [keyFor]; the coach-mark engine
/// (`coach_mark_overlay.dart`) later resolves that key's on-screen rect with
/// [rectFor] to position its spotlight cutout and callout.
///
/// Keeping the ids here (strings, not widget key objects) lets `tour_content`
/// name an anchor without importing any widget, so the single "add a tour
/// entry" rule still lives in one data file — it just also names its UI anchor
/// now.
///
/// Ids are permanent and unique per element. A [keyFor] call always returns the
/// SAME key instance for an id, so the attaching widget and the engine share
/// one key. Only ONE widget may mount a given anchor key at a time (two live
/// widgets with the same [GlobalKey] is a Flutter error) — the nav-bar copy the
/// page-context popup renders therefore does NOT take these keys; only the
/// shell's own bar and its embedded chat composer do.
class TourAnchors {
  TourAnchors._();

  /// The home chat composer (the "say hi to Ayma" text box).
  static const homeComposer = 'home_composer';

  /// The Ayma orb in the nav bar — press & hold to start a voice chat.
  static const homeOrb = 'home_orb';

  /// The Explore tab (taste matches, date rehearsal).
  static const exploreTab = 'explore_tab';

  /// The Messages tab (chats + the in-chat coach).
  static const messagesTab = 'messages_tab';

  /// The Profile tab (Story, Ayma's models, appearance report).
  static const profileTab = 'profile_tab';

  /// The "My story" row inside the Profile tab — a sub-step of the Profile
  /// walkthrough (§11.2a).
  static const profileStoryRow = 'profile_story_row';

  /// The "Appearance" row inside the Profile tab.
  static const profileAppearanceRow = 'profile_appearance_row';

  /// The Settings row inside the Profile tab — the tour's models steps
  /// spotlight it: Ayma's models (her brain + voice) is a row on the
  /// Settings page this row opens.
  static const profileAymaSettingsRow = 'profile_ayma_settings_row';

  /// The notification bell in the nav bar.
  static const notificationsBell = 'notifications_bell';

  /// The chat composer's mic button — tap starts a live call, hold records
  /// an async voice message.
  static const asyncVoiceMic = 'async_voice_mic';

  /// The Explore search field ("describe who you're looking for").
  static const exploreSearch = 'explore_search';

  /// The Explore filter chip row (Everyone / Your likes / Liked me / ...).
  static const exploreFilters = 'explore_filters';

  /// The "My public profile" row inside the Profile tab.
  static const profilePublicProfileRow = 'profile_public_profile_row';

  /// The "Profile details" row inside the Profile tab.
  static const profileDetailsRow = 'profile_details_row';

  /// The "Search the web about me" row inside the Profile tab.
  static const profileWebResearchRow = 'profile_web_research_row';

  /// The "Settings" row inside the Profile tab.
  static const profileSettingsRow = 'profile_settings_row';

  /// The "Plan" row inside the Profile tab.
  static const profilePlanRow = 'profile_plan_row';

  /// The "Notification preferences" row inside Settings.
  static const settingsNotificationsRow = 'settings_notifications_row';

  /// The "Accent Color" row inside Settings.
  static const settingsAccentRow = 'settings_accent_row';

  static final Map<String, GlobalKey> _keys = <String, GlobalKey>{};

  /// The stable [GlobalKey] for [id] — the same instance on every call, so a
  /// widget can attach it and the engine can later find it.
  static GlobalKey keyFor(String id) =>
      _keys.putIfAbsent(id, () => GlobalKey(debugLabel: 'tour:$id'));

  /// The live [BuildContext] of the widget currently carrying [id]'s key, or
  /// null when nothing is mounted for it. The engine uses this to scroll an
  /// off-screen anchor (a Profile row) into view before spotlighting it.
  static BuildContext? contextFor(String id) => _keys[id]?.currentContext;

  /// The global on-screen rect of the widget currently carrying [id]'s key, or
  /// null when nothing is mounted / laid out for it (a gated feature, the wrong
  /// tab, a build that doesn't ship it). A null rect makes the engine skip that
  /// step gracefully rather than block the tour.
  static Rect? rectFor(String id) {
    final context = _keys[id]?.currentContext;
    if (context == null) return null;
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    final origin = object.localToGlobal(Offset.zero);
    return origin & object.size;
  }
}
