
Team roster, status language, communication and testing rules: see docs/agents/TEAM.md

## Ayma registration (every page/feature)

No page or feature merges without its Ayma registration in `functions/bootstrap/app_registry.json`:

- a **registered destination/action** — `key`, `label`, `aliases` in the user's own words, and the **parameterized** form when it takes a person/target (mirror `open_profile` / `open_message_thread` / `open_date_sim` / `open_practice_date`); **or**
- an explicit **`non_navigable`** entry **with a reason**.

A feature is never just absent. Absence is exactly what makes Ayma confabulate a refusal — she denies a real feature exists because she has no route to it (founder bug, build 2246: "I don't have a feature for agent-to-agent simulations", when Agent Dates and Practice Date are headline mechanics).

Enforced mechanically: `functions/bootstrap/tests/test_app_registry.py` and `ayma_flutter/test/app_registry_test.dart` walk every `GoRoute`; `test_app_registry.py::test_imperative_pushes_target_registered_routes_or_listed_subviews` additionally enumerates screens pushed imperatively (`MaterialPageRoute` / `Navigator.push` / `context.push` of a `*Screen` widget) and requires each to be a registered route or a listed sub-view with a reason (`_IMPERATIVE_SUBVIEWS`). A sub-view that is intentionally not a standalone route goes in `_IMPERATIVE_SUBVIEWS` with a one-line reason.
