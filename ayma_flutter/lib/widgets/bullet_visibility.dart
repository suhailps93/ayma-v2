import 'package:flutter/material.dart';

import '../theme.dart';

/// The three bullet visibilities the story/person-graph API speaks.
const bulletVisibilities = ['public', 'private', 'ai_only'];

/// The visibility a tap on the control moves to (public -> private ->
/// Ayma-only -> public).
String nextBulletVisibility(String v) {
  final i = bulletVisibilities.indexOf(v);
  return bulletVisibilities[(i + 1) % bulletVisibilities.length];
}

String bulletVisibilityLabel(String v) => switch (v) {
  'public' => 'Public',
  'ai_only' => 'Ayma-only',
  _ => 'Private',
};

IconData bulletVisibilityIcon(String v) => switch (v) {
  'public' => Icons.public,
  'ai_only' => Icons.auto_awesome,
  _ => Icons.lock_outline,
};

/// Dot / chip colour for a visibility (shared by the editor and the graph).
Color bulletVisibilityColor(AymaTokens ac, String v) => switch (v) {
  'public' => ac.success,
  'ai_only' => ac.secondary,
  _ => ac.warning,
};
