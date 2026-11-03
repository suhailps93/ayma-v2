import 'package:flutter/material.dart';

import '../widgets/legal_link_view.dart';

/// Privacy Policy viewer. Opens the canonical hosted policy — the single
/// source of truth shared with the App Store / Play listing — in the device
/// browser; the app no longer bundles or renders the policy body. Linked from
/// the sign-in screen and the Profile tab, alongside the Terms. Route:
/// `/privacy`.
///
/// The in-app biometric (BIPA) consent text is separate and stays in-app (see
/// `biometric_info_screen.dart`); this screen is only the full-policy viewer.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  static const path = '/privacy';

  /// Canonical hosted Privacy Policy — the single source of truth, also used
  /// by the App Store / Play listing. Served from `docs/PRIVACY.md` →
  /// `public/privacy.html` on Firebase Hosting (project `ayma-ai`);
  /// `firebase.json` rewrites `/privacy-policy` → `/privacy.html`.
  static const url = 'https://ayma-ai.web.app/privacy-policy';

  @override
  Widget build(BuildContext context) =>
      const LegalLinkView(title: 'Privacy Policy', url: url);
}
