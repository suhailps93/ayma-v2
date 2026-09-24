import 'package:flutter/material.dart';

import '../screens/chat_screen.dart';
import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/ayma_session.dart';
import '../services/voice_transport.dart';
import 'ask_ayma_context.dart';
import 'ayma_chat_modal.dart';

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
Future<void> showPageContextAymaPopup(BuildContext context) async {
  final prior = AppContext.instance.current.value;
  await showAymaChatModal(
    context,
    builder: (_) => ChatScreen(
      transcriptStore: AymaSession.instance.store,
      voiceController: AymaSession.instance.voice,
      pageContext: prior,
    ),
  );
  AppContext.instance.set(
    screen: prior.screen,
    subjectUid: prior.subjectUid,
    subjectName: prior.subjectName,
    note: prior.note,
  );
}
