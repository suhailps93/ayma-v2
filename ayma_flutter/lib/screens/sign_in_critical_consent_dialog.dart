import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../legal/sign_in_critical_consent.dart';
import '../theme.dart';
import 'biometric_info_screen.dart';
import 'privacy_screen.dart';
import 'terms_screen.dart';

/// Shows the critical consent items before sign-in (§3.3) — opened when the
/// greeting voice hears "is there anything critical I should be aware of?".
///
/// The wording is the faithful [kSignInCriticalConsentPoints]; the three
/// buttons open the same in-app legal screens the clickwrap links do, so the
/// user can read the full text. Idempotent-safe to show over the sign-in page.
Future<void> showSignInCriticalConsent(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final ac = ctx.ac;
      return AlertDialog(
        scrollable: true,
        title: const Text('Before you sign in'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final point in kSignInCriticalConsentPoints)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '• $point',
                  style: AymaType.sans(size: 14, color: ac.fg),
                ),
              ),
            const SizedBox(height: 4),
            // The full documents — folded into the scrollable body (rather
            // than the actions row) so the dialog stays within short
            // landscape / keyboard-open windows.
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => ctx.push(TermsScreen.path),
                  child: const Text('Terms'),
                ),
                TextButton(
                  onPressed: () => ctx.push(PrivacyScreen.path),
                  child: const Text('Privacy'),
                ),
                TextButton(
                  onPressed: () => ctx.push(BiometricInfoScreen.path),
                  child: const Text('Face matching'),
                ),
              ],
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Got it'),
          ),
        ],
      );
    },
  );
}
