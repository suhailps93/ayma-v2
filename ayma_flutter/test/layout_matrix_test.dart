// Layout robustness matrix (AGENTS.md definition of done: must stay green).
//
// Pumps every routed screen (enumerated against `appRouter`, so a new route
// without an entry in `support/layout_targets.dart` fails here) and the main
// sheets, dialogs and toasts through `kLayoutMatrix` (`support/
// layout_matrix.dart`): tiny phones to the Fold's inner display, landscape,
// 300px split-screen windows, text scale up to 2.0, keyboard open, RTL,
// bold/high-contrast, light/dark, a non-default accent. Fails on any
// RenderFlex overflow, unbounded constraint or other exception. Split into
// shards (this file and `layout_matrix_shard*_test.dart`) so `flutter test`
// runs them in parallel.
import 'support/layout_targets.dart';

void main() => defineLayoutMatrix(shard: 0, shards: 3);
