import '../screens/chat_screen.dart';
import '../screens/main_shell_screen.dart';
import '../screens/preboarding_flow_screen.dart';

/// Where the app opens for a given server-derived `session_mode` (§3.3, §11.2).
/// `session_mode` is authoritative — the client never decides it itself.
String entryRouteFor(String sessionMode) {
  switch (sessionMode) {
    case 'active':
      return MainShellScreen.path;
    case 'interview':
      return PreboardingFlowScreen.path;
    case '':
      // The server always sends a real `session_mode` (even alongside
      // `recovery_required` / `usage_capped`); an empty one means a malformed
      // response, not "pre-signup". A signed-in user belongs in the shell, not
      // dumped into the pre-signup marketing chat.
      return MainShellScreen.path;
    case 'marketing':
    default:
      return ChatScreen.path;
  }
}
