import 'package:flutter/material.dart';

import '../legal/privacy_text.dart';
import '../theme.dart';
import '../widgets/markdown_text.dart';
import '../widgets/ayma_back_button.dart';

/// Privacy Policy. A plain scrollable render of [kPrivacyText] (generated from
/// `docs/PRIVACY.md`). Linked from the sign-in screen and the Profile tab,
/// alongside the Terms. Route: `/privacy`.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  static const path = '/privacy';

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Privacy Policy')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          child: MarkdownText(
            kPrivacyText.trim(),
            style: AymaType.sans(size: 14, color: ac.fg, height: 1.55),
          ),
        ),
      ),
    );
  }
}
