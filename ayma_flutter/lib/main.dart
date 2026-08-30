import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'routing/app_router.dart';
import 'services/push_service.dart';
import 'services/theme_controller.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await _ensureSignedIn();
  await themeControllerGlobal.load();
  // Register this device for push (§7.2). Fire-and-forget — never blocks the
  // first frame, and failure is non-fatal.
  unawaited(PushService().syncToken());
  runApp(const AymaApp());
}

/// Cold-start auth (ARCHITECTURE.md §3.3): every session begins signed in. If
/// there is no Firebase user yet, create an anonymous one — the `marketing`
/// session runs on a real but credential-less `uid`. A real credential is
/// linked onto this same `uid` in place later (Step 5).
Future<void> _ensureSignedIn() async {
  final auth = FirebaseAuth.instance;
  if (auth.currentUser != null) return;
  try {
    await auth.signInAnonymously();
  } on FirebaseAuthException catch (e) {
    // Transient (offline) or config failures: log and continue. Later steps
    // that gate on `session_mode` handle a null user.
    debugPrint('Anonymous sign-in failed: ${e.code} ${e.message}');
  }
}

/// Root of the Ayma app.
///
/// Step 4: `go_router` with placeholder screens (splash / preboarding / main
/// shell). Real redirect logic and the 4-tab shell come later.
class AymaApp extends StatelessWidget {
  const AymaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: themeControllerGlobal,
      builder: (context, _) => MaterialApp.router(
        title: 'Ayma',
        debugShowCheckedModeBanner: false,
        theme: AymaTheme.light,
        darkTheme: AymaTheme.dark,
        themeMode: themeControllerGlobal.mode,
        routerConfig: appRouter,
      ),
    );
  }
}
