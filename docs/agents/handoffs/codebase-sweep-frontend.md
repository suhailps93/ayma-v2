# Codebase sweep, chunk 2 of 2 — frontend (Flutter)

Scope: `ayma_flutter/lib` (152 files, ~48k lines: 47 screens, 49 services, 40 widgets; 124 test files). Report only — no application code changed. Method: line/structure inventory, route-table cross-check (48 `GoRoute`s), per-file importer counts across lib + test, normalized diffs of suspected clones, flag/endpoint usage tracing, marker greps (TODO/print), state-pattern census.

## Findings, ranked by impact

1. `services/api_client.dart` (4,489 lines, 108 methods + ~60 DTO classes at lines 2179-4489) — monolith client; half the file is DTOs while `models/` holds only 3 files. Move DTOs to `models/` first, then split methods by domain (chat/story, reports, matches/DM, billing, media, account).
2. `services/wiki_service.dart` — dead in prod: zero importers in `lib`, referenced only by its own test. The Story editor + `story*`/`wiki/*` api methods replaced it. Delete file + `test/wiki_service_test.dart` (highest value, near-zero risk).
3. Every `ApiClient()` ctor opens a new `http.Client` never closed (`api_client.dart:22`), and ~20 call sites construct one ad hoc (`?? ApiClient()` in screens, widgets, services). Share one instance or a static client before the split in #1.
4. `screens/chat_screen.dart` (3,777 lines; `_ChatScreenState` spans ~163-2536 plus 15 helper classes) — god-state. Extract along existing seams: transcript/bubble (`_TranscriptLine`), composer wiring, voice wiring, `_PendingSendReconcile`.
5. `services/match_activity.dart` (56) vs `services/deep_dive_activity.dart` (79) — same singleton-poll skeleton, drifted: deep-dive has a wall-clock deadline + `failed` set + required api; match has a count-only bound (40×3s, Android freeze can outlive the server cutoff) and builds its own client. Extract a shared poll base.
6. `widgets/face_report_view.dart` hosts shared helpers (`resolvePhotoUrl(s)`, `AddToStoryButton`) that `body_report_view.dart` imports from it — works, but asymmetric; move to a shared report-helpers file so face/body/appearance all import sideways.
7. Public helpers living in a screen file: `ProfilePhotoHeader`/`ProfileBody` in `screens/public_profile_screen.dart` (1,108 lines) are imported by `matches_screen.dart` and `widgets/inline_photo_carousel.dart` — move to `widgets/`.
8. `services/screen_capture.dart` (744 lines) mixes app services with widgets (`NoScreenContext`, `NoAymaAction`) plus the semantics-capture engine and `perform` — move the wrappers to `widgets/`, keep the engine in `services/`.
9. Direct `FirebaseFirestore`/`FirebaseAuth` reads in 13 screens (trial_paywall, underage, splash, appearance_report, delete_account, profile_tab, story_editor, profile_settings, my_public_profile, biometric_consent_settings, sign_in, preboarding_flow, developer) vs the service/api layer everywhere else — document the rule (direct reads OK? writes via api?) or migrate.
10. Oversized-but-sectioned, split along existing private classes when touched: `screens/story_editor_screen.dart` (1,597: `_StoryTabBar`/`_StoryCover`/`_PhotosSection` → widgets), `screens/dm_thread_screen.dart` (1,028), `screens/plan_screen.dart` (998), `widgets/living_report_view.dart` (1,429, 17 row classes → report-rows file), `widgets/ayma_orb.dart` (1,726: painter + `_WingDef`/`_StateParams` extractable), `widgets/chat_composer.dart` (796, already shared by chat + dm — good), `services/voice_session_controller.dart` (840).
11. Two bubble implementations: dm `_Bubble` (`dm_thread_screen.dart:780`) vs chat `_TranscriptLine` (`chat_screen.dart:2786`); composer is shared but bubbles diverged — unify on one when either is next touched.
12. Parked Meta code (deliberate, V2-deferred, `meta_integrations=false`): `screens/instagram_screen.dart` (181) + `services/instagram_service.dart` (64) + 5 api methods + gated route — carrying cost only; don't half-clean, remove or ship at the V2 decision.
13. `services/chat_service.dart` (53) is `ChatImageUpload` + a thin wrapper — the name overpromises next to `chat_inbox`/`pending_chat_queue`/`transcript_store` (all distinct, all fine). Rename on next touch.
14. `services/dev_panel_flag.dart` vs `services/sentry_config.dart` — two flag-doc parsers encoding the same "missing=ON, literal false=off" rule; share one parser if a third flag client appears.
15. `debugPrint` in 16 lib files (`voice_session_controller` ×19, `voice_transport` ×12) — debug-only noise; route through the logging package when in the area.

## Explicitly checked, no action needed

- No dead screens: 47 screens, 45 routed; `VoiceCallScreen` is pushed from `chat_screen.dart:1396`, `ManualProfileEditScreen` from `my_public_profile_screen.dart`, `push_primer_dialog.dart` is a dialog fn used by preboarding — all alive with tests.
- No dead widgets/services besides #2: the four zero-cross-import widgets (`score_bar`, `notification_bell`, `messages_unread_icon`, `ask_ayma_action`) are same-dir imports, all used; `pair_key.dart` is used by `app_command_service` + `notification_service`.
- No stale flags: `dev_panel` + `sentry` live and mirrored; `meta_integrations` off by design. Two share paths are distinct by design (`share_report_sheet` = in-app DM recipient share, `report_card_share_sheet` = image-card external share, with cross-refs). Push trio (`push_permission`/`push_service`/`notification_service`), billing chain (`revenuecat_service`/`subscription_status`/`trial_paywall_gate`/`credits_balance`), settings pair (`settings_screen` hub vs `ayma_settings_screen`), voice pair (controller phase-machine vs transport) are all layered, not duplicated.
- State mgmt is consistent: no Riverpod/Bloc/Provider; hand-rolled `ChangeNotifier` (9) + `ValueNotifier` (13) + `setState` (50 files) + `FutureBuilder` (14). Zero TODO/FIXME/`print(` in lib.
- Chunk-1 note: finding #14 says `scripts/flags.py` doesn't exist, but it exists and is documented in `docs/FEATURE_FLAGS.md` on this branch — re-verify before "fixing" the references.

## Suggested cleanup order

Delete dead wiki code (#2) first; then sideways moves with no behavior change (#6, #7, #8); then the activity merge (#5) and shared http client (#3); then `api_client` DTO extraction (#1, models first, methods after); god-state/split work (#4, #10, #11) last, one per commit with the layout-matrix gate green. #12 waits for the V2 decision; #9 is a rule to write down before any migration; #13-15 are drive-by only.
