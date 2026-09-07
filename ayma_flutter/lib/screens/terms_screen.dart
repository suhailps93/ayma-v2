import 'package:flutter/material.dart';

import '../legal/terms_text.dart';
import '../theme.dart';
import '../widgets/markdown_text.dart';

/// Terms of Service (§ auto analysis §5). A plain scrollable render of
/// [kTermsText] (generated from `docs/TERMS.md`). Linked from the sign-in
/// screen and the Profile tab. Route: `/terms`.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static const path = '/terms';

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Terms of Service')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          child: MarkdownText(
            kTermsText.trim(),
            style: AymaType.sans(size: 14, color: ac.fg, height: 1.55),
          ),
        ),
      ),
    );
  }
}
