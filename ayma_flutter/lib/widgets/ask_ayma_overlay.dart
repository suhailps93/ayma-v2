import 'package:flutter/material.dart';

import '../screens/chat_screen.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/screen_capture.dart';
import '../services/ayma_session.dart';
import '../services/voice_transport.dart';
import 'ask_ayma_context.dart';
import 'ayma_chat_modal.dart';
import 'ayma_tab_bar.dart';

export 'ask_ayma_context.dart';

/// Opens the Ask Ayma turn: the ONE shared dockable chat modal
/// ([showAymaChatModal]) hosting the ONE shared chat core ([ChatScreen],
/// scoped via its `askAymaContext` field — see that field's doc for exactly
/// what changes in this mode), carrying [ctx] into the real `/chat` (or
/// `/chat/stream`) pipeline — the same one ordinary passage edits already
/// use, and the same conversational agent + tools every other Ayma surface
/// in the app uses.
///
/// [onExchange] fires after every reply Ayma gives while the modal is open
/// (not just once at the end) so the caller can quietly re-fetch the section
/// and flash the sentence that changed while the user is still mid-conversation,
/// without leaving the document. Returns once the modal is dismissed (tap
/// outside, drag down past its minimum size, or the header's close button).
Future<void> showAskAymaOverlay(
  BuildContext context, {
  required ApiClient api,
  required AskAymaContext ctx,
  VoidCallback? onExchange,
  @visibleForTesting ApiClient? voiceApiClient,
  @visibleForTesting VoiceTransport Function()? voiceTransportFactory,
}) {
  return showAymaChatModal(
    context,
    builder: (_) => ChatScreen(
      apiClient: api,
      askAymaContext: ctx,
      onExchange: onExchange,
      voiceApiClient: voiceApiClient,
      voiceTransportFactory: voiceTransportFactory,
    ),
  );
}

/// Opens the same dockable chat modal as [showAskAymaOverlay], scoped to
/// wherever the user currently is (`AppContext.instance`) rather than one
/// specific passage/block — the Ayma orb's behavior everywhere except the
/// Ayma tab itself (founder ask: tapping the orb from another tab or a
/// pushed screen should pop up a scoped chat "like the story edit", not jump
/// to the main tab — see `AymaTabBar`'s own doc for the three call sites).
///
/// Unlike [showAskAymaOverlay] (an ephemeral, `askAymaContext`-scoped
/// correction turn — see [ChatScreen.askAymaContext]'s doc), this embeds
/// [ChatScreen] via its plain [ChatScreen.pageContext] field instead, against
/// the app-wide [AymaSession] store/voice controller [MainShellScreen]'s own
/// Ayma tab already uses — so the popup shows the SAME real conversation
/// history (and any live call) as the main tab, with that tab's own plain
/// "Ayma" header and message styling, not the separate sparkle-icon "Ask
/// Ayma" branded chrome [showAskAymaOverlay]'s scoped turns use. The "you
/// were looking at…" chip above the composer (`ChatScreen`'s existing
/// `pageContext`/`_pageContext` chip) carries the context instead of a
/// quoted-passage card, since there's no single passage here — just "whatever
/// page the user was on".
///
/// [AppContext.instance] is snapshotted once, before the modal opens — not
/// re-read live — and restored after the modal closes: [ChatScreen] itself
/// sets it to `'ayma'` for the voice mirror's `current_screen` tool while
/// open (same as the main tab does), which would otherwise leave the app
/// thinking the user is still "on" Ayma after they've dismissed the popup and
/// gone back to whatever they were doing.
///
/// [navBarBuilder] rebuilds the caller's own `AymaTabBar` (same index/
/// voiceActive/onSelected it already renders in its own tree) as a second,
/// on-top copy inside the popup itself, so the bar stays visible and
/// tappable while this is open (founder complaint: "Navbar don't show when
/// chat popup is open") — see [showAymaChatModal]'s `persistentBottomBar`
/// doc for why a *copy* rendered inside the popup, not just "leave a gap
/// so the real one underneath peeks through". Passing the caller's exact
/// `onSelected` here also means a second orb tap, from that copy, runs
/// through the exact same tap-handling as the real bar — including its
/// "already open" branch (see [isPageContextAymaPopupOpen]).
///
/// The header's expand button and a second orb tap both grow this same
/// sheet to full screen in place ([pageContextAymaPopupSheet]); see
/// [showAymaChatModal] for the transition and why nothing is re-mounted.
Future<void> showPageContextAymaPopup(
  BuildContext context, {
  required WidgetBuilder navBarBuilder,
}) async {
  // Fresh capture of the page under the popup (its route, text, controls).
  ScreenCapture.instance.refreshNow();
  final rawPrior = AppContext.instance.current.value;
  // `screen == 'ayma'` means "the mirror hadn't updated off the Ayma tab
  // yet" (a real switch's own `AppContext.set` can lag a synchronous tap by
  // a frame) rather than a genuine other page — pinning a "you were on
  // Ayma" chip onto a popup that IS Ayma reads as nonsense, so treat it the
  // same as no context at all instead of surfacing the raw screen slug
  // (`ScreenContext.label`'s fallback for an unmapped screen name).
  final prior =
      rawPrior.screen == 'ayma' ? const ScreenContext() : rawPrior;
  isPageContextAymaPopupOpen = true;
  final future = showAymaChatModal(
    context,
    persistentBottomBar: navBarBuilder,
    persistentBottomBarHeight:
        AymaTabBar.contentHeight + MediaQuery.paddingOf(context).bottom,
    controller: pageContextAymaPopupSheet,
    builder: (_) => ChatScreen(
      transcriptStore: AymaSession.instance.store,
      voiceController: AymaSession.instance.voice,
      pageContext: prior,
    ),
  );
  pendingPageContextAymaPopup = future;
  try {
    await future;
  } finally {
    // In a `finally`, not just after the `await` — if `showAymaChatModal`
    // ever throws (or the route is torn down some way other than its normal
    // dismiss paths), these must not get stuck forever, which would
    // silently break every later orb tap (see each `AymaTabBar` call site's
    // `_onTabTap`).
    isPageContextAymaPopupOpen = false;
    pendingPageContextAymaPopup = null;
  }
  // Restores the screen the user was ACTUALLY on before this popup opened —
  // `rawPrior`, not the display-filtered `prior` above, so a real 'ayma'
  // mirror value gets put back exactly as it was rather than cleared.
  AppContext.instance.set(
    screen: rawPrior.screen,
    subjectUid: rawPrior.subjectUid,
    subjectName: rawPrior.subjectName,
    note: rawPrior.note,
  );
}

/// Whether the popup [showPageContextAymaPopup] opens is currently showing —
/// a plain top-level flag (not `ChangeNotifier`/`ValueNotifier`) since every
/// reader here is a synchronous tap handler (`AymaTabBar`'s `onSelected` in
/// `NavBarShell`, `MainShellScreen`, `PublicProfileScreen`), never a widget
/// that needs to rebuild when it flips. A second orb tap while this is true
/// expands the open popup to full screen ([pageContextAymaPopupSheet])
/// instead of stacking a second popup on top — see each of those call
/// sites' own `_onTabTap`.
bool isPageContextAymaPopupOpen = false;

/// Expands/collapses the popup [showPageContextAymaPopup] opens. One shared
/// instance, since at most one such popup is ever open; with none open its
/// calls are no-ops.
final pageContextAymaPopupSheet = AymaChatSheetController();

/// The still-pending [showAymaChatModal] Future from the currently-open
/// popup, if any — whoever pops the popup to act on the page behind it
/// (`main.dart`'s `ScreenCapture.beforeAct`, a non-orb tab tap in
/// `NavBarShell`/`PublicProfileScreen`) `await`s this before going on.
Future<void>? pendingPageContextAymaPopup;
