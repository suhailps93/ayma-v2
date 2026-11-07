import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a hosted legal page (Terms of Service, Privacy Policy) in the
/// device browser.
///
/// There is deliberately no screen for this: tapping a Terms or Privacy
/// link anywhere in the app calls [openTerms] / [openPrivacy] from the
/// screen the user is already on, and the hosted page opens directly in
/// the browser on top of it. The user returns to exactly where they were.
///
/// If the browser cannot be opened (the launcher reports failure or
/// throws), a small dialog appears on that same screen saying so, showing
/// the address and offering a retry — never a full-screen page in between.
typedef LegalUrlLauncher = Future<bool> Function(Uri url);

class LegalLinks {
  const LegalLinks._();

  /// Shown in links, buttons and the failure dialog.
  static const String termsTitle = 'Terms of Service';
  static const String privacyTitle = 'Privacy Policy';

  /// Canonical hosted Terms of Service — the single source of truth, also
  /// used by the App Store / Play listing. Served from `docs/TERMS.md` ->
  /// `public/terms.html` on Firebase Hosting (project `ayma-ai`).
  /// Link directly to `/terms.html`: the bare `/terms` path 404s on the
  /// live Firebase Hosting deploy (verified 2026-11-07 by page content).
  static const String termsUrl = 'https://ayma-ai.web.app/terms.html';

  /// Canonical hosted Privacy Policy — the single source of truth, also
  /// used by the App Store / Play listing. Served from `docs/PRIVACY.md` ->
  /// `public/privacy.html` on Firebase Hosting (project `ayma-ai`);
  /// `firebase.json` rewrites `/privacy-policy` -> `/privacy.html`.
  static const String privacyUrl = 'https://ayma-ai.web.app/privacy-policy';

  static Future<bool> _launchExternally(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  /// The launcher every open goes through. Tests replace it to record the
  /// URLs that would have opened and to simulate a failed open, without a
  /// real browser or platform channel.
  static LegalUrlLauncher launcher = _launchExternally;

  @visibleForTesting
  static void setLauncherForTesting(LegalUrlLauncher? value) {
    launcher = value ?? _launchExternally;
  }

  /// One open attempt: true when the browser accepted the page.
  static Future<bool> tryOpen(String url) async {
    try {
      return await launcher(Uri.parse(url));
    } catch (_) {
      return false;
    }
  }

  static Future<void> openTerms(BuildContext context) =>
      open(context, title: termsTitle, url: termsUrl);

  static Future<void> openPrivacy(BuildContext context) =>
      open(context, title: privacyTitle, url: privacyUrl);

  /// Opens [url] in the browser from [context]; on failure, shows the
  /// in-place error dialog on the caller's screen (with the address and a
  /// retry) and stays there.
  static Future<void> open(
    BuildContext context, {
    required String title,
    required String url,
  }) async {
    if (await tryOpen(url)) return;
    if (!context.mounted) return;
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('legal_link_error_dialog'),
        title: Text('Could not open $title'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'We could not open it in your browser. You can try again, '
              'or visit this address:',
            ),
            const SizedBox(height: 12),
            SelectableText(url),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('legal_link_error_close'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Close'),
          ),
          FilledButton(
            key: const Key('legal_link_error_retry'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
    if (retry == true && context.mounted) {
      await open(context, title: title, url: url);
    }
  }
}
