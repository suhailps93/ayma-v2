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

  /// The Explore tab (taste matches / Qloo, date rehearsal).
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

  /// The "Ayma's settings" row inside the Profile tab (her brain + voice).
  static const profileAymaSettingsRow = 'profile_ayma_settings_row';

  /// The play/preview button beside the VOICE selector on the "Ayma's models"
  /// voice screen (`/settings/voice`) — a pushed screen, not a shell tab, so
  /// this anchor resolves only while that screen is open and otherwise skips.
  static const voicePreview = 'voice_preview_button';

  /// The notification bell in the nav bar.
  static const notificationsBell = 'notifications_bell';

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
