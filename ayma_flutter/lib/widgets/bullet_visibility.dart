import 'package:flutter/material.dart';

import '../theme.dart';

/// The bullet visibilities the user can set in Your Story. Ayma-only is NOT
/// here: it is for Ayma alone and never shown in Your Story (founder order,
/// Nov 15 2026), so the user only ever toggles public <-> private.
const bulletVisibilities = ['public', 'private'];

/// The visibility a tap on the control moves to (public <-> private). A bullet
/// that somehow still carries 'ai_only' resolves to 'private' on the next tap.
String nextBulletVisibility(String v) {
  final i = bulletVisibilities.indexOf(v);
  if (i < 0) return 'private';
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
