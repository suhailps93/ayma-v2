import 'package:flutter/material.dart';

import '../screens/chat_screen.dart';
import '../services/api_client.dart';
import '../services/voice_transport.dart';
import 'ask_ayma_context.dart';
import 'ayma_chat_modal.dart';

export 'ask_ayma_context.dart';

/// Opens the Ask Ayma turn: the ONE shared dockable chat modal
/// ([showAymaChatModal], the same treatment the floating Ayma orb launcher
/// opens — see `global_ayma_launcher.dart`) hosting the ONE shared chat core
/// ([ChatScreen], scoped via its `askAymaContext` field — see that field's
/// doc for exactly what changes in this mode), carrying [ctx] into the real
/// `/chat` (or `/chat/stream`) pipeline — the same one ordinary passage edits
/// already use, and the same conversational agent + tools every other Ayma
/// surface in the app uses.
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
