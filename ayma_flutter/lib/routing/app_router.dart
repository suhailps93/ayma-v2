import 'package:go_router/go_router.dart';

import '../screens/main_shell_screen.dart';
import '../screens/preboarding_screen.dart';
import '../screens/splash_screen.dart';

/// App router (Step 4 skeleton).
///
/// Placeholder routes only — splash, preboarding, main shell — with no redirect
/// logic yet. The `session_mode`-driven `redirect` from §11.2 and the deep-link
/// routes from §11.5 (`chat`, `profile/{uid}`, `dm_thread/{threadId}`) are added
/// in later steps.
final appRouter = GoRouter(
  initialLocation: SplashScreen.path,
  routes: [
    GoRoute(
      path: SplashScreen.path,
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: PreboardingScreen.path,
      builder: (context, state) => const PreboardingScreen(),
    ),
    GoRoute(
      path: MainShellScreen.path,
      builder: (context, state) => const MainShellScreen(),
    ),
  ],
);
