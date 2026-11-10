import 'package:flutter/material.dart';

import '../legal/privacy_text.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/markdown_text.dart';

/// The "Biometric information (face matching)" section of the Privacy Policy
/// on its own page — linked from the sign-in page's face-recognition consent
/// checkbox. Readable before sign-in. Route: `/legal/biometric`.
class BiometricInfoScreen extends StatelessWidget {
  const BiometricInfoScreen({super.key});

  static const path = '/legal/biometric';
  static const _heading = '## Biometric information (face matching)';

  /// The section as it appears in [kPrivacyText] (up to the next heading).
  static String section() {
    final start = kPrivacyText.indexOf(_heading);
    if (start < 0) return kPrivacyText.trim();
    final end = kPrivacyText.indexOf('\n## ', start + _heading.length);
    return kPrivacyText
        .substring(start, end < 0 ? kPrivacyText.length : end)
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Biometric information'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: MarkdownText(
            section(),
            style: AymaType.sans(size: 14, color: ac.fg, height: 1.55),
          ),
        ),
      ),
    );
  }
}
