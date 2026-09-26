import 'ids.dart';
import 'transcript_store.dart';
import 'voice_session_controller.dart';

/// The single Ayma chat session for the whole app's lifetime: one
/// [TranscriptStore] and one [VoiceSessionController], app-wide singletons —
/// never disposed, same lifecycle shape as `AppContext.instance` /
/// `ChatInbox.instance`.
///
/// The 4-tab shell's Ayma tab ([MainShellScreen]) embeds a real `ChatScreen`
/// against these exact instances by default, and `NavBarShell`'s bar reads
/// [voice] directly (its orb glows/pulses for a live call from any screen in
/// the app), so the conversation history and any live voice session are
/// identical no matter where in the app they're read from. Lives as a
/// standalone singleton (not owned by [MainShellScreen]) so it survives that
/// screen being torn down and rebuilt by a flat-routing `context.go` — e.g.
/// `NavBarShell`'s own tab taps (see `nav_bar_shell.dart`).
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
