import 'package:flutter/material.dart';

import '../legal/terms_text.dart';
import '../theme.dart';
import '../widgets/markdown_text.dart';
import '../widgets/ayma_back_button.dart';

/// Terms of Service (§ auto analysis §5). A scrollable render of
/// [kTermsText] (generated from `docs/TERMS.md`), under a boxed
/// [kTermsKeyPoints] summary. Linked from the sign-in
/// screen and the Profile tab. Route: `/terms`.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static const path = '/terms';

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Terms of Service')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                key: const Key('terms_key_points'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: ac.accentFaint,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: ac.accent, width: 1.5),
                ),
                child: MarkdownText(
                  kTermsKeyPoints.trim(),
                  style: AymaType.sans(size: 14, color: ac.fg, height: 1.5),
                ),
              ),
              const SizedBox(height: 20),
              MarkdownText(
                kTermsText.trim(),
                style: AymaType.sans(size: 14, color: ac.fg, height: 1.55),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
