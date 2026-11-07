import 'package:flutter/material.dart';

import '../services/legal_links.dart';
import '../widgets/legal_redirect.dart';

/// Legacy `/privacy` route — no longer a screen.
///
/// Tapping Privacy Policy anywhere in the app opens the canonical hosted
/// policy directly in the browser from the screen the user is already on
/// (see [LegalLinks.openPrivacy]); nothing navigates here. The route
/// stays registered for paths that arrive from outside a tap (Ayma
/// opening the page through the app registry, a queued deep link), and
/// arriving here opens the browser and goes straight back — see
/// [LegalRedirect]. There is no Privacy Policy page in the app any more.
///
/// The in-app biometric (BIPA) consent text is separate and stays in-app
/// (see `biometric_info_screen.dart`).
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  static const path = '/privacy';

  /// Canonical hosted Privacy Policy — see [LegalLinks.privacyUrl].
  static const url = LegalLinks.privacyUrl;

  @override
  Widget build(BuildContext context) =>
      const LegalRedirect(title: LegalLinks.privacyTitle, url: url);
}
