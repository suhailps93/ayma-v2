import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/age_gate.dart';
import '../theme.dart';
import 'sign_in_screen.dart';
import 'terms_screen.dart';

/// Hard stop for anyone under 18 (Ayma is strictly 18+). Shown when a
/// birthdate under 18 is entered, or when the server reports the account is
/// closed for age. There is no way forward from here: no back button, no route
/// into the app — only the Terms, and signing out.
class UnderageScreen extends StatelessWidget {
  const UnderageScreen({super.key, this.signOut});

  static const path = '/under-18';

  /// Overridable for tests; defaults to Firebase sign-out.
  final Future<void> Function()? signOut;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(AgeGate.mustBeAdultMessage,
                    key: const Key('underage_title'),
                    style: AymaType.serif(size: 28, color: ac.fg)),
                const SizedBox(height: 12),
                Text(
                  "Ayma is for adults only, so we can't let you in. "
                  "We're sorry — come back when you're 18.",
                  style: AymaType.sans(size: 15, color: ac.fgDim, height: 1.5),
                ),
                const SizedBox(height: 28),
                OutlinedButton(
                  key: const Key('underage_terms'),
                  onPressed: () => context.push(TermsScreen.path),
                  child: const Text('Read the Terms'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('underage_sign_out'),
                  onPressed: () async {
                    try {
                      await (signOut ?? FirebaseAuth.instance.signOut)();
                    } catch (_) {/* sign-in redirect below still applies */}
                    if (context.mounted) context.go(SignInScreen.path);
                  },
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
