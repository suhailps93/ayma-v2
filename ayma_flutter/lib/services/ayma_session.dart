import 'ids.dart';
import 'transcript_store.dart';
import 'voice_session_controller.dart';

/// The single Ayma chat session for the whole app's lifetime: one
/// [TranscriptStore] and one [VoiceSessionController], app-wide singletons —
/// never disposed, same lifecycle shape as `AppContext.instance` /
/// `ChatInbox.instance`.
///
/// Both the 4-tab shell's Ayma tab ([MainShellScreen]) and the global
/// floating chat sheet ([GlobalAymaLauncher]) embed a real `ChatScreen`
/// against these exact instances by default, so the conversation history and
/// any live voice session are identical no matter which surface reached
/// them. Lives above the router (owned here, not inside any one screen)
/// because the floating launcher must reach it from outside
/// `MainShellScreen`'s widget tree.
class AymaSession {
  AymaSession._();
  static final AymaSession instance = AymaSession._();

  final String sessionId = newSessionId();
  final TranscriptStore store = TranscriptStore();
  late final VoiceSessionController voice = VoiceSessionController(
    transcriptStore: store,
    sessionId: sessionId,
  );
}
