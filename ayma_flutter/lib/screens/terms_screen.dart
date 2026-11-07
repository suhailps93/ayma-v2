import 'package:flutter/material.dart';

import '../widgets/legal_link_view.dart';

/// Terms of Service viewer. Opens the canonical hosted Terms — the single
/// source of truth shared with the App Store / Play listing — in the device
/// browser; the app no longer bundles or renders the Terms body. Linked from
/// the sign-in screen and the Profile tab. Route: `/terms`.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static const path = '/terms';

  /// Canonical hosted Terms of Service — the single source of truth, also used
  /// by the App Store / Play listing. Served from `docs/TERMS.md` →
  /// `public/terms.html` on Firebase Hosting (project `ayma-ai`).
  /// Link directly to `/terms.html`: the bare `/terms` path 404s on the
  /// live Firebase Hosting deploy (verified 2026-11-07 by page content).
  static const url = 'https://ayma-ai.web.app/terms.html';

  @override
  Widget build(BuildContext context) =>
      const LegalLinkView(title: 'Terms of Service', url: url);
}
