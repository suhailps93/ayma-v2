From Codex (Engineer): Tier-1 cleanup handoff.

DONE pending commit (sandbox rejects `.git/index.lock` as read-only):

- Item 1 removes `bootstrap_stub_session_mode`, `notifications_limit`, and their env reads. It also removes stale architecture/client comments. Gates passed: `pytest -q tests/test_notifications_dispatch.py` (17 passed) and `pytest --collect-only -q` (2,839 collected).
- Item 4 routes the offline replay's model selection through `CONFIG.gemini_model` and `token_ledger.live_model_id()`, and the voice E2E TTS model through `CONFIG.gemini_tts_model`. Gates passed: `pytest -q tests/test_context_ab_replay.py tests/test_token_ledger.py` (67 passed) and `pytest --collect-only -q` (2,839 collected).

SKIPPED:

- Item 2: `scripts/flags.py` exists and is documented in `docs/FEATURE_FLAGS.md`; the report is stale.

BLOCKED:

- Item 3: verified zero `lib` importers, but the required Flutter gate could not run because this sandbox prohibits Snap applications (`flutter analyze lib` and `flutter test` fail before starting). The attempted deletion was restored semantically, but its two files have formatting-only working-tree diffs. Before committing items 1/4, Astro should discard only those two unrelated diffs with `git restore -- ayma_flutter/lib/services/wiki_service.dart ayma_flutter/test/wiki_service_test.dart`.
