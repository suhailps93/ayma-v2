import 'package:flutter/material.dart';

import '../release_notes.dart';
import '../theme.dart';
import '../widgets/markdown_text.dart';
import '../widgets/ayma_back_button.dart';

/// "What's new" — a plain scrollable render of [kReleaseNotes] (newest version
/// first). Reached only from inside the unlocked Developer panel — normal
/// users never see the full changelog. Route: `/whats-new`.
class ReleaseNotesScreen extends StatelessWidget {
  const ReleaseNotesScreen({super.key});

  static const path = '/whats-new';

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text("What's new")),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: MarkdownText(
            kReleaseNotes.trim(),
            style: AymaType.sans(size: 14, color: ac.fg, height: 1.55),
          ),
        ),
      ),
    );
  }
}
