import 'package:flutter/material.dart';

import '../services/legal_links.dart';
import '../widgets/legal_redirect.dart';

/// Legacy `/terms` route — no longer a screen.
///
/// Tapping Terms of Service anywhere in the app opens the canonical
/// hosted Terms directly in the browser from the screen the user is
/// already on (see [LegalLinks.openTerms]); nothing navigates here.
/// The route stays registered for paths that arrive from outside a tap
/// (Ayma opening the page through the app registry, a queued deep link),
/// and arriving here opens the browser and goes straight back — see
/// [LegalRedirect]. There is no Terms page in the app any more.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static const path = '/terms';

  /// Canonical hosted Terms of Service — see [LegalLinks.termsUrl].
  static const url = LegalLinks.termsUrl;

  @override
  Widget build(BuildContext context) =>
      const LegalRedirect(title: LegalLinks.termsTitle, url: url);
}
