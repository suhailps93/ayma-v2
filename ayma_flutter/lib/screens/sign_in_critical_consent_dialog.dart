import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../legal/sign_in_critical_consent.dart';
import '../services/legal_links.dart';
import '../theme.dart';
import 'biometric_info_screen.dart';

/// Shows the critical consent items before sign-in (§3.3) — opened when the
/// greeting voice hears "is there anything critical I should be aware of?".
///
/// The wording is the faithful [kSignInCriticalConsentPoints]; the Terms
/// and Privacy buttons open the hosted documents directly in the browser
/// (the same documents the clickwrap links open), and the face-matching
/// button opens its in-app section, so the user can read the full text.
/// Idempotent-safe to show over the sign-in page.
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
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: () => LegalLinks.openTerms(ctx),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  child: const Text('Terms'),
                ),
                TextButton(
                  onPressed: () => LegalLinks.openPrivacy(ctx),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  child: const Text('Privacy'),
                ),
                TextButton(
                  onPressed: () => ctx.push(BiometricInfoScreen.path),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
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
