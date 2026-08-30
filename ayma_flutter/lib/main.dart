import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await _ensureSignedIn();
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
    // that gate on `session_mode` handle a null user; Step 3's blank screen
    // renders regardless.
    debugPrint('Anonymous sign-in failed: ${e.code} ${e.message}');
  }
}

/// Root of the Ayma app.
///
/// Still a single blank screen — routing and the app shell arrive in Step 4,
/// the chat screen in Step 8.
class AymaApp extends StatelessWidget {
  const AymaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Ayma',
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: SizedBox.expand()),
    );
  }
}
