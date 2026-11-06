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
