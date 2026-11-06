# F1 client idle-arm fix — Scout note 122 (build 2324)

Status: **DONE**

Branch: `fleet/opencode-f1-client-idle` (staging only — not merged)

## Root cause

The client user-idle timer was armed in `_onAgentReady()` when the LiveKit room
and agent were ready (`phase -> live (agent ready)`). On a cold call that is
~8 seconds before the agent produces its first genuine response — the moment the
UI actually reads "Listening…" and the microphone opens (`isConversationReady`).
So the 30 s budget had already spent ~8 s by the time the call became usable and
fired at live+22 s, matching the device log line
`client user idle timeout fired — disconnect reason: client_idle_timeout`.

## Fix

- `ayma_flutter/lib/services/voice_session_controller.dart:847` — `_onAgentReady()`
  no longer arms the user-idle clock at agent/room setup. It only arms there if
  a genuine response already arrived before the `waking -> live` promotion
  (warm-worker race, line 854).
- `ayma_flutter/lib/services/voice_session_controller.dart:903` — the clock is
  now armed in `_noteAgentResponse()` (line 912), the true live line: the first
  genuine agent response, when `isConversationReady` becomes true.
- `ayma_flutter/lib/services/voice_session_controller.dart:165` — kept the
  continuation's `_userIdleArmedAt` field and `userIdleArmedAtForTest` getter
  (line 176).
- `ayma_flutter/lib/services/voice_session_controller.dart:1010` — `_armUserIdleTimer()`
  records `_userIdleArmedAt = DateTime.now()` and logs
  `[voice] user idle timer armed at <ISO8601> (+<ms>ms)`.
- `ayma_flutter/lib/services/voice_session_controller.dart:1023` — user-activity
  re-arms also refresh `_userIdleArmedAt`.
- Timestamp is cleared when the timer is no longer armed: reset block (line 547),
  fire (line 1034), teardown (line 1445), dispose (line 1657).

Net behaviour on a cold no-input call: agent joins at T, first response at
T+~8 s, clock arms then, and the call ends ~30 s after the real live line
(T+~38 s) instead of T+30 s / live+22 s.

## Regression test

`ayma_flutter/test/voice_user_idle_timeout_test.dart:330` — new test 7
("cold no-input clock starts at the first Ayma response (true live), not
agent-ready"): asserts `userIdleArmedAtForTest` is null after agent-ready,
non-null after the first agent response, still live 200 ms after agent-ready
(the old live+22 s-shaped failure), and idle 200 ms after the first response.
Test 1 (line 76) was updated to emit an opening agent response first, matching a
real call's true live line.

## Verification

`cd ayma_flutter && flutter analyze lib/services/voice_session_controller.dart test/voice_user_idle_timeout_test.dart`
→ `No issues found!`

`cd ayma_flutter && flutter test test/voice_session_controller_test.dart test/voice_connecting_state_test.dart test/voice_mic_lifecycle_test.dart test/voice_tool_guard_test.dart test/voice_call_screen_test.dart test/voice_user_idle_timeout_test.dart`
→ `All tests passed!` (92 tests)

## Push

Pushed to local shared origin `/home/suhailps/workspace/ayma` on
`fleet/opencode-f1-client-idle`. Not merged into staging.
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
