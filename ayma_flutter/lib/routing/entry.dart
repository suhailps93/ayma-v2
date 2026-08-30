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
    case 'marketing':
    default:
      return ChatScreen.path;
  }
}
