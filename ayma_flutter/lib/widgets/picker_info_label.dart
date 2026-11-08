import 'package:flutter/material.dart';

import '../theme.dart';

/// A picker field label with a small eye icon beside it (founder,
/// 2026-11-07): the Models screen stays clean — no section headers, no
/// always-visible explanation paragraphs — and each picker's short
/// explanation lives behind its eye. Tapping the eye opens a small sheet
/// saying what changing that setting does.
class PickerInfoLabel extends StatelessWidget {
  const PickerInfoLabel({
    super.key,
    required this.label,
    required this.infoKey,
    required this.title,
    required this.explanation,
  });

  /// The small mono field label, e.g. 'BRAIN'.
  final String label;

  /// Key for the eye button, e.g. 'picker-info-brain'.
  final String infoKey;

  /// Sheet title, e.g. 'Brain'.
  final String title;

  /// One or two short plain sentences shown in the sheet.
  final String explanation;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            label,
            style: AymaType.mono(size: 10, color: ac.fgMute)
                .copyWith(letterSpacing: 1.5),
          ),
          const Spacer(),
          IconButton(
            key: ValueKey(infoKey),
            icon: const Icon(Icons.visibility_outlined, size: 18),
            color: ac.fgMute,
            tooltip: 'What does this do?',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => showPickerExplanation(
              context,
              title: title,
              explanation: explanation,
            ),
          ),
        ],
      ),
    );
  }
}

/// The small sheet behind a picker's eye icon: the picker's name and what
/// changing it does, in one or two short plain sentences.
void showPickerExplanation(
  BuildContext context, {
  required String title,
  required String explanation,
}) {
  final ac = context.ac;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: AymaType.sans(
                  size: 16, weight: FontWeight.w600, color: ac.fg),
            ),
            const SizedBox(height: 8),
            Text(
              explanation,
              style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
            ),
          ],
        ),
      ),
    ),
  );
}
