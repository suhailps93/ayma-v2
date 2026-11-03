# Read-Only Review: GW-SCROLL Op-Specific Fix (Staging Tip 8c0c73a)

**Reviewer:** Antigravity (Engineer)  
**Date:** 2026-11-02 17:27 PT  
**Target Commit:** `8c0c73a` (`fix/gw-scroll-hang` merged to `staging`, build `1.30.0+2256`)  
**Base Commit:** `be284ac` / `80806b9` (build 2255)  
**Specimen Under Review:** Daniel goes to Explore via chat sheet, then orb, then says "scroll to the bottom", on an Explore grid of ~7 cards that fits on screen.  
**Review Scope:** Strictly read-only; zero app code edits; LiveKit routing preserved untouched.

---

## Executive Summary

| Review Point | Verdict | Summary |
|---|---|---|
| **Point 1: Scout's Failing Specimen (Daniel on Explore grid of ~7 cards)** | **COVERED** | When ~7 cards fit on screen, Flutter's `RenderViewport` has zero scroll extent and exposes no `scrollUp`/`scrollDown` semantics actions. `ScreenCapture.perform()` detects `nothingScrollable`, intercepts the missing target, and returns `UiActionResult.done("Reached the bottom — the whole page already fits on screen.")` instead of a refusal. |
| **Point 2: Honest-Completion Guarantee & Variant-A (Profile Scroll)** | **COVERED** | User message persistence at turn-start (`_persist_user_turn`) and honest finalization (`_finalize_chat`) remain completely intact. Variant-A (`/profile/user/u1`) maintains non-zero scroll extent, resolves target `[list]`, and runs `_scrollToEnd` to completion. |
| **Point 3: Test Coverage (Short-List / Fits-On-Screen Case)** | **COVERED** | `screen_capture_test.dart:455–500` explicitly models Scout's specimen at 1200x2400, asserts `controls.any(type == 'list')` is false, and confirms `perform()` returns `ok: true` containing `'fits on screen'`. |
| **Point 4: Edge Cases & GridView Node-Finding Path** | **GAP** | **Documented Contract Discrepancy:** The code at `screen_capture.dart:694` checks `op.startsWith('scroll') && nothingScrollable`, but omits `control.trim().isEmpty`. If the model requests a *named* control (e.g. `control: "l99"`) on a page without scrollables, it returns `done` ("already fits on screen") instead of refusing ("that control isn't on screen any more"), directly violating the documented contract in `ARCHITECTURE.md`, the code comments, and the commit message. |

---

## 1. Point 1: Specimen Analysis (Daniel on Explore)

### Verdict: COVERED

### Mechanism & Execution Trace
1. **Explore Screen Structure:**
   - In [explore_screen.dart:369–386](file:///home/suhailps/workspace/ayma/.fleet-worktrees/gwscrollb-refix-review/ayma_flutter/lib/screens/explore_screen.dart#L369-L386), the feed is rendered with a `CustomScrollView` and `SliverGrid(gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 240, ...))`.
   - On a standard modern mobile viewport (or Fold/tablet), ~7 profile cards fit completely within the vertical height. The viewport's `maxScrollExtent` is `0.0`.
2. **Flutter Semantics Omission:**
   - Flutter's `RenderViewportBase` attaches `SemanticsAction.scrollUp` and `SemanticsAction.scrollDown` only when `hasContentDimensions && minScrollExtent != maxScrollExtent`.
   - Consequently, in [screen_capture.dart:290–293](file:///home/suhailps/workspace/ayma/.fleet-worktrees/gwscrollb-refix-review/ayma_flutter/lib/services/screen_capture.dart#L290-L293), `_typeOf(SemanticsData d)` finds neither scroll action and returns `null`. The `CustomScrollView` is never tagged as a `'list'` control and is absent from `snap.controls`.
3. **Target Resolution:**
   - Daniel speaks "scroll to the bottom". In [skills/app_control_ui.py:50–66](file:///home/suhailps/workspace/ayma/.fleet-worktrees/gwscrollb-refix-review/functions/bootstrap/skills/app_control_ui.py#L50-L66), page scrolls omit the control ID: `{"action": "ui_action", "control": "", "label": "", "op": "scroll_to_bottom"}`.
   - [screen_capture.dart:757–765](file:///home/suhailps/workspace/ayma/.fleet-worktrees/gwscrollb-refix-review/ayma_flutter/lib/services/screen_capture.dart#L757-L765) (`_resolve`):
     ```dart
     final id = control.trim().toLowerCase();
     if (id.isEmpty && op.startsWith('scroll')) {
       for (final c in snap.controls) {
         if (c.type == 'list') return c;
       }
       return null;
     }
     ```
     Because no control in `snap.controls` has `type == 'list'`, `_resolve()` returns `null`.
4. **Graceful Handling in Commit 8c0c73a:**
   - In [screen_capture.dart:686–700](file:///home/suhailps/workspace/ayma/.fleet-worktrees/gwscrollb-refix-review/ayma_flutter/lib/services/screen_capture.dart#L686-L700):
     ```dart
     final nothingScrollable = !snap.controls.any((c) => c.type == 'list');
     if (op.startsWith('scroll') && nothingScrollable) {
       final where = op == 'scroll_to_top' ? 'the top' : 'the bottom';
       final head = _scrollEndOps.contains(op)
           ? 'Reached $where — the whole page already fits on screen.'
           : 'Nothing to scroll — the whole page already fits on screen.';
       return UiActionResult.done('$head\n${snap.visible}');
     }
     ```
   - `nothingScrollable` evaluates to `true`.
   - `op` starts with `'scroll'`, `_scrollEndOps.contains('scroll_to_bottom')` is `true`.
   - Returns `UiActionResult.done` with `ok = true` and `result = "Reached the bottom — the whole page already fits on screen.\n..."`.
5. **Backend & Turn Completion:**
   - `AppCommandService._runUiAction` writes `ack` doc with `ok: true`.
   - `skills/app_control_ui.py:80–85` receives `ack["ok"] == True` and returns `Done: scroll_to_bottom on the screen. Screen now: Reached the bottom — the whole page already fits on screen...`.
   - The model does not encounter an error, does not re-read or retry, and concludes the turn with an honest message to Daniel.

---

## 2. Point 2: Honest-Completion Guarantee & Variant-A (Profile Scroll)

### Verdict: COVERED

### Evidence & Analysis
1. **Honest Completion Guarantee:**
   - Commit `8c0c73a` touched only Flutter client code (`screen_capture.dart`, `pubspec.yaml`, `screen_capture_test.dart`) and documentation.
   - Backend persistence in `functions/bootstrap/main.py:1675–1695` (`_persist_user_turn`) remains fully active: user turns are written to Firestore `chat_messages` before generation starts.
   - Backend completion in `functions/bootstrap/main.py:1700–1740` (`_finalize_chat`) and `_CHAT_INCOMPLETE_REPLY` fallback remain fully active.
   - Client-side execution in `AppCommandService.runUiAction` ([app_command_service.dart:294–302](file:///home/suhailps/workspace/ayma/.fleet-worktrees/gwscrollb-refix-review/ayma_flutter/lib/services/app_command_service.dart#L294-L302)) catches all exceptions and acks cleanly.
2. **Variant-A Preservation (Profile Scroll Op):**
   - Public profile screens (`/profile/user/u1`) render a multi-card `ListView` extending past the bottom edge.
   - Flutter sets `maxScrollExtent > 0` and attaches `SemanticsAction.scrollUp` / `scrollDown`.
   - `_typeOf()` tags it `list`, so `snap.controls` includes `[l1] list`.
   - `_resolve()` finds `[l1] list` (`target != null`).
   - The `if (target == null)` branch is skipped entirely.
   - `_scrollToEnd(owner, target.nodeId, action)` executes normally. Because the profile is a finite list (not paginated), extent growth is stable, and it completes with `"Reached the bottom."`.
   - Verified passing by automated widget test in [screen_capture_test.dart:538–569](file:///home/suhailps/workspace/ayma/.fleet-worktrees/gwscrollb-refix-review/ayma_flutter/test/screen_capture_test.dart#L538-L569) (`scroll_to_bottom scrolls the page revealed when the Ask Ayma sheet is dismissed first (/profile/user/u1)`).

---

## 3. Point 3: Test Coverage Audit

### Verdict: COVERED

### Evidence & Analysis
The new test in [screen_capture_test.dart:455–500](file:///home/suhailps/workspace/ayma/.fleet-worktrees/gwscrollb-refix-review/ayma_flutter/test/screen_capture_test.dart#L455-L500) specifically tests the failing specimen under real semantics conditions:
```dart
testWidgets(
    'scroll_to_bottom on a short Explore grid that fits on screen returns a '
    'graceful result, never an error (GW-SCROLL: Daniel on Explore)',
    (tester) async {
  final handle = tester.ensureSemantics();
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 240, childAspectRatio: 0.66),
            delegate: SliverChildBuilderDelegate(
              (c, i) => Card(
                  child: Center(child: Text(const [
                'Daniel', 'Sofia', 'Priya', 'Alexander', 'Mia', 'Noah', 'Ava'
              ][i]))),
              childCount: 7,
            ),
          ),
        ],
      ),
    ),
  ));
  await tester.pumpAndSettle();
  final cap = ScreenCapture(
    routeOf: () => '/explore',
    settle: () => tester.pumpAndSettle(),
  );
  // The grid fits, so it is not a scrollable control at all.
  expect(cap.capture().controls.any((c) => c.type == 'list'), isFalse);
  final r = await cap.perform(control: '', label: '', op: 'scroll_to_bottom');
  expect(r.ok, isTrue, reason: r.reason);
  expect(r.result, contains('fits on screen'));
  expect(r.result, isNot(contains("isn't on screen")));
  handle.dispose();
});
```

**Coverage Verification:**
- Physical size `1200x2400` ensures 7 cards fit on screen without scroll overflow.
- Verifies the exact negative precondition (`controls.any(type == 'list')` is false).
- Verifies `perform` returns `r.ok == true` and includes `'fits on screen'`.
- Negative assertion: `expect(r.result, isNot(contains("isn't on screen")))`.
- All 17 widget tests in `screen_capture_test.dart` pass in 3 seconds.

---

## 4. Point 4: Edge Cases & Discrepancies (GridView Node-Finding Path)

### Verdict: GAP (Documented Contract Discrepancy for Named Controls)

### Discovered Discrepancy: Missing `control.isEmpty` Check
1. **Contract as Documented:**
   - Commit `8c0c73a` commit message:
     > *"A named control that is genuinely gone still refuses (read again) — only a page scroll with no scrollable at all is treated as 'already fully visible'."*
   - Code comment at [screen_capture.dart:692](file:///home/suhailps/workspace/ayma/.fleet-worktrees/gwscrollb-refix-review/ayma_flutter/lib/services/screen_capture.dart#L692):
     > *"A named control that is genuinely gone still refuses."*
   - [docs/ARCHITECTURE.md:624](file:///home/suhailps/workspace/ayma/.fleet-worktrees/gwscrollb-refix-review/docs/ARCHITECTURE.md#L624):
     > *"A named control that is genuinely gone still refuses."*
2. **Code in Staging Tip `8c0c73a`:**
   ```dart
   final nothingScrollable = !snap.controls.any((c) => c.type == 'list');
   if (op.startsWith('scroll') && nothingScrollable) {
     final where = op == 'scroll_to_top' ? 'the top' : 'the bottom';
     final head = _scrollEndOps.contains(op)
         ? 'Reached $where — the whole page already fits on screen.'
         : 'Nothing to scroll — the whole page already fits on screen.';
     return UiActionResult.done('$head\n${snap.visible}');
   }
   return const UiActionResult.refused(
       "that control isn't on screen any more; read the screen again");
   ```
3. **Failure Mode:**
   - If a caller explicitly specifies a control ID that does not exist or has disappeared (e.g. `perform(control: "l99", label: "Favorites", op: "scroll_down")`) on a page that currently has no scrollable list:
     - `_resolve()` returns `null`.
     - `nothingScrollable` evaluates to `true`.
     - The code enters `if (op.startsWith('scroll') && nothingScrollable)` and returns `UiActionResult.done(...)`!
     - It **fails to refuse** the nonexistent named control.
   - It only refuses a missing named control if *another* list is present on the screen (`nothingScrollable == false`).
4. **Recommended Fix for Claude:**
   Add `control.trim().isEmpty` to the condition:
   ```dart
   if (op.startsWith('scroll') && control.trim().isEmpty && nothingScrollable) {
   ```
   This ensures that named control operations that cannot be resolved always refuse with `"that control isn't on screen any more; read the screen again"`.

### Architecture of GridView Node-Finding
- The fix correctly chose an op-level graceful resolution rather than hacking Flutter's semantics tree.
- Attempting to force Flutter's `RenderViewport` to synthesize a semantics scroll action when `maxScrollExtent == 0` would cause action dispatch failures or crashes during framework scrolling.
- Handling it in `perform()` keeps the semantics tree honest and accurately reflects that the viewport cannot be scrolled.
- Route security and consent barriers (`kNoContextRoutes` in `screen_capture.dart:681`, `ui_denial` in `app_control_ui.py:60–62`) are evaluated before target resolution and remain uncompromised.

---

## 5. Scout Retest Readiness & Next Steps

1. **Scout Specimen Readiness:**
   - Staging tip `8c0c73a` (build `2256`) is **READY** for Scout's retest of Daniel on Explore. Page-level scrolls send `control: ""`, which cleanly takes the graceful exit.
2. **Follow-Up for Claude:**
   - Patch `screen_capture.dart:694` to include `control.trim().isEmpty` so missing named controls are refused as documented.
