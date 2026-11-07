import 'package:flutter/material.dart';

import '../screens/chat_screen.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/screen_capture.dart';
import '../services/ayma_session.dart';
import '../services/transcript_store.dart';
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
/// use — or, for [AskAymaOrigin.report], into `POST
/// /report/{type}/{id}/correct`, the same conversational agent + tools every
/// other Ayma surface in the app uses.
///
/// ONE chat (§ D13): this is the main chat conversation, not a silo — the
/// sheet is built against the main history ([AymaSession]'s store, unless a
/// test passes its own [transcriptStore]) and the exchange lands in it (and,
/// for the report path, in server chat history too), so it reads the same
/// from the Ayma tab afterwards. The partial sheet does not LIST that
/// history (founder rule, Nov 2026 — context card, chips and composer
/// only); expanding reveals the whole conversation. The sheet opens docked
/// (a partial page of the main chat) with the host's bottom nav bar visible
/// (resolved from the nearest [AymaNavBarScope]; unwrapped routes simply get
/// no bar, as before), and a second orb tap grows it to the full chat in
/// place ([orbTapOnOpenSheet]).
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
  TranscriptStore? transcriptStore,
  @visibleForTesting ApiClient? voiceApiClient,
  @visibleForTesting VoiceTransport Function()? voiceTransportFactory,
}) async {
  final navBar = AymaNavBarScope.builderOf(context);
  isAymaSheetOpen = true;
  isAymaSheetScoped = true;
  final future = showAymaChatModal(
    context,
    persistentBottomBar: navBar,
    persistentBottomBarHeight: navBar == null ? null : AymaTabBar.heightFor,
    controller: aymaSheet,
    builder: (_) => ChatScreen(
      apiClient: api,
      transcriptStore: transcriptStore ?? AymaSession.instance.store,
      askAymaContext: ctx,
      onExchange: onExchange,
      voiceApiClient: voiceApiClient,
      voiceTransportFactory: voiceTransportFactory,
    ),
  );
  pendingAymaSheet = future;
  try {
    await future;
  } finally {
    // Same must-not-stick reasoning as [showPageContextAymaPopup]'s own
    // `finally` below.
    isAymaSheetOpen = false;
    isAymaSheetScoped = false;
    pendingAymaSheet = null;
  }
}

/// Opens the same dockable chat modal as [showAskAymaOverlay], scoped to
/// wherever the user currently is (`AppContext.instance`) rather than one
/// specific passage/block — the Ayma orb's behavior everywhere except the
/// Ayma tab itself (founder ask: tapping the orb from another tab or a
/// pushed screen should pop up a scoped chat "like the story edit", not jump
/// to the main tab — see `AymaTabBar`'s own doc for the three call sites).
///
/// Unlike [showAskAymaOverlay] (an `askAymaContext`-scoped correction turn —
/// see [ChatScreen.askAymaContext]'s doc), this embeds [ChatScreen] via its
/// plain [ChatScreen.pageContext] field instead, against the app-wide
/// [AymaSession] store/voice controller [MainShellScreen]'s own Ayma tab
/// already uses — so the popup shares the SAME real conversation (and any
/// live call) as the main tab, with that tab's own plain "Ayma" header
/// and message styling, not the separate sparkle-icon "Ask Ayma" branded
/// chrome [showAskAymaOverlay]'s scoped turns use. While partial the popup
/// lists none of that history (founder rule, Nov 2026 — composer only);
/// expanding reveals the whole conversation. The "you were looking
/// at…" chip above the composer (`ChatScreen`'s existing
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
/// "already open" branch (see [isAymaSheetOpen]).
///
/// The header's expand button (or a drag up) grows this same sheet to
/// full screen in place ([aymaSheet]); see [showAymaChatModal] for the
/// transition and why nothing is re-mounted. A second orb tap does NOT
/// grow it — it closes the sheet and navigates to the real main chat
/// screen instead (see [orbTapOnOpenSheet]).
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
  isAymaSheetOpen = true;
  isAymaSheetScoped = false;
  final future = showAymaChatModal(
    context,
    persistentBottomBar: navBarBuilder,
    persistentBottomBarHeight: AymaTabBar.heightFor,
    controller: aymaSheet,
    builder: (_) => ChatScreen(
      transcriptStore: AymaSession.instance.store,
      voiceController: AymaSession.instance.voice,
      pageContext: prior,
    ),
  );
  pendingAymaSheet = future;
  try {
    await future;
  } finally {
    // In a `finally`, not just after the `await` — if `showAymaChatModal`
    // ever throws (or the route is torn down some way other than its normal
    // dismiss paths), these must not get stuck forever, which would
    // silently break every later orb tap (see each `AymaTabBar` call site's
    // `_onTabTap`).
    isAymaSheetOpen = false;
    isAymaSheetScoped = false;
    pendingAymaSheet = null;
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

/// Whether ANY Ayma chat sheet is currently showing — the orb's
/// page-context popup ([showPageContextAymaPopup]) or a scoped Ask-Ayma
/// correction turn ([showAskAymaOverlay]); at most one is ever open, since a
/// second orb tap acts on the open one instead of stacking another (see
/// [orbTapOnOpenSheet]).
/// A plain top-level flag (not `ChangeNotifier`/`ValueNotifier`) since every
/// reader here is a synchronous tap handler (`AymaTabBar`'s `onSelected` in
/// `NavBarShell`, `MainShellScreen`, `PublicProfileScreen`), never a widget
/// that needs to rebuild when it flips.
bool isAymaSheetOpen = false;

/// Whether the currently-open sheet ([isAymaSheetOpen]) is a scoped Ask-Ayma
/// correction turn rather than the plain page-context popup — decides the
/// orb tap's third rung (see [orbTapOnOpenSheet]). Meaningless while no
/// sheet is open.
bool isAymaSheetScoped = false;

/// Expands/collapses the open Ayma chat sheet. One shared instance, since at
/// most one such sheet is ever open; with none open its calls are no-ops.
final aymaSheet = AymaChatSheetController();

/// The still-pending [showAymaChatModal] Future from the currently-open
/// sheet, if any — whoever pops the sheet to act on the page behind it
/// (`ScreenCapture.beforeAct`, a non-orb tab tap in
/// `NavBarShell`/`PublicProfileScreen`) `await`s this before going on.
Future<void>? pendingAymaSheet;

/// An orb tap while [isAymaSheetOpen]. Second-tap detection is exactly
/// this state at tap time — the sheet is open, it is not yet expanded,
/// and it is the plain page-context popup (not a scoped correction turn):
///
/// * docked PLAIN sheet -> [onGoToMainChat], when the caller supplies one:
///   the second tap closes the sheet and navigates to the REAL main chat
///   screen (the shell's Ayma tab / `MainShellScreen.path`), it does not
///   grow the overlay into a full-screen dialog over the current page
///   (founder report, 2026-11-06: the grown overlay hid every page Ayma
///   navigated to behind it). Callers without a main-chat destination
///   (tests, synthetic hosts) omit it and keep the old expand behaviour.
/// * expanded PLAIN sheet -> [onVoice]: the tap progression's third rung.
///   Full screen here is only reachable now via the header expand button
///   or a drag — those entry points are unchanged.
/// * a scoped correction turn ([isAymaSheetScoped]) never takes the voice
///   rung and never navigates away, at any size: it grows to full screen
///   in place instead. The voice agent doesn't bind its correction tools,
///   so a full-duplex call from one could only ever answer "I can't do
///   that" — its voice stays push-to-talk via the composer's own mic
///   button, which sends through the same scoped turn pipeline as typed
///   text.
void orbTapOnOpenSheet({
  required VoidCallback onVoice,
  VoidCallback? onGoToMainChat,
}) {
  if (aymaSheet.isExpanded && !isAymaSheetScoped) {
    onVoice();
  } else if (!aymaSheet.isExpanded &&
      !isAymaSheetScoped &&
      onGoToMainChat != null) {
    onGoToMainChat();
  } else {
    aymaSheet.expand();
  }
}

/// Dismisses the currently-open Ayma chat sheet and waits until its
/// dismissal has completed ([pendingAymaSheet] resolves). This is a
/// dismissal only — it is NOT a page navigation: it records no route, tab
/// or go-back history entry, and callers perform the actual destination
/// navigation themselves after it returns, so the destination is what
/// becomes visible once the sheet is gone. A no-op when no sheet is open.
Future<void> dismissOpenAymaSheet(BuildContext context) async {
  if (!isAymaSheetOpen) return;
  Navigator.of(context).pop();
  await pendingAymaSheet;
}

/// Exposes the host screen's own bottom-bar builder to Ask-Ayma sheets
/// opened from anywhere in its subtree, so [showAskAymaOverlay]'s scoped
/// turns can keep the bar visible (as a [showAymaChatModal]
/// `persistentBottomBar` copy) without every opener threading a builder down
/// by hand — its callers (`LivingReportView`, the Story editor) sit deep in
/// screens they know nothing about. Provided by the three bar hosts
/// ([MainShellScreen], [NavBarShell], `PublicProfileScreen`); absent (null)
/// on unwrapped routes and in tests, where the sheet opens bar-less, as
/// before.
class AymaNavBarScope extends InheritedWidget {
  const AymaNavBarScope({
    super.key,
    required this.navBarBuilder,
    required super.child,
  });

  final WidgetBuilder navBarBuilder;

  static WidgetBuilder? builderOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AymaNavBarScope>()?.navBarBuilder;

  @override
  bool updateShouldNotify(AymaNavBarScope oldWidget) => false;
}
