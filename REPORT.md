# Tour-overlay fix — mid-tour composer stays tappable (Scout note 118 leg 4)

## What was wrong
On the composer step of a guided tour, the message box sat inside the spotlight hole but its text field never took focus: every tap inside the hole unfocused the field and fired `onTapped()`, so the user could not type or send mid-tour. Two root causes, both verified in staging code:
1. `coach_mark_overlay.dart` `_onPointerUp` unfocused and fired `onTapped()` for ANY in-hole tap in driven mode.
2. `tour_host.dart` `_prepareStep` unfocused before every step.

## What changed (branch `fleet/opencode-tour-overlay`, off staging `4a178c7d`)
- `lib/services/tour_content.dart` — new `TourFeature.typingAllowed` flag (default false); set to true on the home-composer feature only.
- `lib/services/app_command_service.dart` — the composer step is built with `typingAllowed: anchor == TourAnchors.homeComposer`.
- `lib/widgets/coach_mark_overlay.dart` — on a typing-allowed step, taps that are not on the mic return early: no unfocus, no `onTapped`, no advance. Only the mic is an anchor tap here. Also observes `WidgetsBinding` so the spotlight hole re-resolves when view metrics change (keyboard opening pushes the composer up).
- `lib/widgets/tour_host.dart` — `_prepareStep` no longer unfocuses on typing-allowed steps, so the keyboard is never yanked away while the user types.
- `test/coach_mark_overlay_test.dart` — 5 new widget tests: text-field tap keeps focus and does not fire `onTapped` (typing works); Send and Attach press through but do not advance; mic tap fires `onTapped`; mic advances the passive tour; spotlight follows the composer when the keyboard opens.

Behavior on a typing-allowed step: text field keeps focus, typing and Send work, Send/Attach act on the real composer without moving the tour, the mic advances the tour, Done / Skip still move it forward. The tour stays at step 0 while typing.

## Verification (run by Astro on the ThinkPad, Nov 6 2026)
- `flutter test test/coach_mark_overlay_test.dart` — 16/16 passed (11 pre-existing + 5 new).
- `flutter analyze` on all 5 touched files — No issues found.
- Diff reviewed file by file against the fix spec before committing; no unrelated changes included.

## Provenance
OpenCode wrote the fix across two sessions that both died before committing (first 09:44 PT on a TLS error, second silent after 10:06 PT, ended 10:46 PT). Astro verified the preserved worktree diff, ran the tests and analyze, committed, and pushed. Untracked leftovers in the clone (`ROUTE_COVERAGE_TASK.md`, `opencode.json`, from an earlier chunk) were intentionally NOT committed.

## Status
Ready for delta review (deltareview44). Staging only — not merged. On merge, Scout retests leg 4 on-device with the tour poller and the `tour_event` watch.
