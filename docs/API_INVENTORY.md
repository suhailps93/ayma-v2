# API Inventory

Complete inventory of the HTTP surface of the Python FastAPI backend, extracted from the source code.

> Note: there is no `server/` directory in this repository. The FastAPI backend lives at `functions/bootstrap/`; its entry point is `functions/bootstrap/main.py` (Cloud Run service). This inventory covers that package.

## Authentication and global gates

All routes are registered on one FastAPI `app` (`main.py`), either directly or through the routers below. Two gates apply app-wide and are therefore not repeated in every row:

- `require_biometric_consent` — app-level FastAPI dependency (`main.py:529`). Any request carrying a valid Firebase ID token is refused with `403 biometric_consent_required` until the caller has a biometric-consent record. Exempt paths: `/health`, `/bootstrap`, `/age-gate/declare`, `/biometric-consent`, `/biometric-consent/withdraw`, `/account/delete`, `/account/recover`, `/welcome/token`, `/instagram/signin-auth-url`, `/instagram/signin`, `/auth/email-exists`, `/notifications/token`, `/notifications/token/remove`. Public/unauthenticated routes and requests without a valid token pass through to their own auth logic.
- `RateLimiter` middleware (`main.py:613`) — per-endpoint fixed-window rate limiting.

Auth helpers referenced in the tables (`functions/bootstrap/auth.py` unless noted):

| Dependency | Meaning |
| --- | --- |
| `require_uid` | Verifies the Firebase Bearer ID token and returns the uid. |
| `require_caller` | Like `require_uid`, also returns a `Caller` (`uid`, `is_anonymous`, `sign_in_provider`). |
| `require_adult_uid` | `require_uid` + adult (birthdate on file) gate; defined in `main.py:343` and mirrored in `routes/profile.py:28`. |
| `require_not_underage_uid` | `require_uid` + refuses minors, allows users without a birthdate; defined in `main.py:330` and `practice_date.py:101`. |
| `require_dev` | `require_uid` + dev-view allowlist (`403` otherwise). |
| `require_uid_and_dev_flag` | `require_uid` and reports whether the caller is on the dev allowlist. |
| `require_admin_password` | Requires the `X-Admin-Password` header. |
| `require_cron` | Requires the `X-Cron-Secret` header. |
| `require_revenuecat` | Requires the RevenueCat webhook `Authorization` header. |
| `_require_meta_integrations` | Feature-flag gate; returns `404` while `meta_integrations` is off (`main.py:4096`). |

## Route counts by router

| Router / module | Routes |
| --- | --- |
| `main.py` | 125 |
| `practice_date.py` (prefix `/practice`) | 4 |
| `date_sim.py` | 5 |
| `taste_match.py` | 3 |
| `routes/appearance.py` | 7 |
| `routes/cron.py` | 14 |
| `routes/media.py` | 8 |
| `routes/profile.py` | 9 |
| `routes/story.py` | 13 |
| MCP sub-app (`mcp_server.py`, mounted at `/mcp`) | 11 (10 routes + catch-all mount) |
| **Total** | **199** |

## Application routes — `main.py`

_125 routes._

| Method | Path | Handler | Source | Auth dependency |
| --- | --- | --- | --- | --- |
| `GET` | `/health` | `health` | `functions/bootstrap/main.py:645` | none (public) |
| `POST` | `/bootstrap` | `bootstrap` | `functions/bootstrap/main.py:692` | require_caller |
| `POST` | `/onboarding/complete` | `onboarding_complete` | `functions/bootstrap/main.py:922` | require_uid |
| `POST` | `/welcome/token` | `welcome_token` | `functions/bootstrap/main.py:982` | none (public) |
| `POST` | `/chat` | `chat` | `functions/bootstrap/main.py:1908` | require_not_underage_uid + require_caller |
| `POST` | `/chat/stream` | `chat_stream` | `functions/bootstrap/main.py:2098` | require_not_underage_uid + require_caller |
| `POST` | `/post-turn` | `post_turn` | `functions/bootstrap/main.py:2350` | require_uid |
| `GET` | `/chat/history` | `chat_history_page` | `functions/bootstrap/main.py:2381` | require_uid |
| `POST` | `/voice/context` | `set_voice_context` | `functions/bootstrap/main.py:2431` | require_uid |
| `DELETE` | `/voice/context` | `clear_voice_context` | `functions/bootstrap/main.py:2457` | require_uid |
| `POST` | `/voice/async` | `voice_async` | `functions/bootstrap/main.py:2472` | require_not_underage_uid + require_caller |
| `GET` | `/verification/status` | `verification_status` | `functions/bootstrap/main.py:2534` | require_uid |
| `POST` | `/verification/selfie` | `verification_selfie` | `functions/bootstrap/main.py:2556` | require_uid |
| `POST` | `/account/delete` | `account_delete` | `functions/bootstrap/main.py:2636` | require_uid |
| `POST` | `/account/recover` | `account_recover` | `functions/bootstrap/main.py:2652` | require_uid |
| `GET` | `/biometric-consent` | `biometric_consent_status` | `functions/bootstrap/main.py:2682` | require_uid |
| `POST` | `/biometric-consent` | `biometric_consent_accept` | `functions/bootstrap/main.py:2696` | require_not_underage_uid |
| `POST` | `/biometric-consent/withdraw` | `biometric_consent_withdraw` | `functions/bootstrap/main.py:2724` | require_uid |
| `POST` | `/age-gate/declare` | `age_gate_declare` | `functions/bootstrap/main.py:2746` | require_uid |
| `GET` | `/explore` | `explore` | `functions/bootstrap/main.py:2770` | require_adult_uid |
| `GET` | `/explore/profile/{other_uid}` | `explore_profile` | `functions/bootstrap/main.py:2829` | require_adult_uid |
| `POST` | `/deep-dive` | `deep_dive_endpoint` | `functions/bootstrap/main.py:2896` | require_uid |
| `GET` | `/deep-dive-report/{report_id}` | `deep_dive_report` | `functions/bootstrap/main.py:2963` | require_uid |
| `GET` | `/deep-dive/mine` | `deep_dive_mine` | `functions/bootstrap/main.py:3032` | require_uid |
| `POST` | `/deep-dive/{report_id}/facts/{fact_id}/dispute` | `deep_dive_dispute_fact` | `functions/bootstrap/main.py:3069` | require_uid |
| `POST` | `/deep-dive/{report_id}/correct` | `deep_dive_correct` | `functions/bootstrap/main.py:3109` | require_uid |
| `GET` | `/web-search/photos/candidates` | `web_search_photo_candidates` | `functions/bootstrap/main.py:3158` | require_uid |
| `POST` | `/web-search/photos/rescan` | `web_search_photo_rescan` | `functions/bootstrap/main.py:3179` | require_uid |
| `POST` | `/web-search/photos/candidates/{candidate_id}/confirm` | `web_search_photo_confirm` | `functions/bootstrap/main.py:3196` | require_uid |
| `POST` | `/web-search/photos/candidates/{candidate_id}/reject` | `web_search_photo_reject` | `functions/bootstrap/main.py:3212` | require_uid |
| `POST` | `/face-report` | `face_report_endpoint` | `functions/bootstrap/main.py:3388` | require_uid |
| `POST` | `/body-report` | `body_report_endpoint` | `functions/bootstrap/main.py:3398` | require_uid |
| `GET` | `/skills/report/{kind}/{report_id}` | `skills_report` | `functions/bootstrap/main.py:3407` | require_uid |
| `GET` | `/skills/reports/{kind}` | `skills_reports` | `functions/bootstrap/main.py:3448` | require_uid |
| `POST` | `/profiles/mini` | `profiles_mini` | `functions/bootstrap/main.py:3517` | require_adult_uid |
| `POST` | `/explore/like` | `explore_like` | `functions/bootstrap/main.py:3570` | require_adult_uid |
| `POST` | `/explore/unlike` | `explore_unlike` | `functions/bootstrap/main.py:3610` | require_adult_uid |
| `POST` | `/explore/pass` | `explore_pass` | `functions/bootstrap/main.py:3655` | require_adult_uid |
| `POST` | `/dm/{thread_id}/messages` | `dm_send` | `functions/bootstrap/main.py:3685` | require_adult_uid |
| `POST` | `/dm/assist` | `dm_assist_endpoint` | `functions/bootstrap/main.py:3859` | require_adult_uid |
| `POST` | `/dm/translate` | `dm_translate_endpoint` | `functions/bootstrap/main.py:3886` | require_adult_uid |
| `POST` | `/share` | `share_create` | `functions/bootstrap/main.py:3929` | require_adult_uid |
| `POST` | `/share/revoke` | `share_revoke` | `functions/bootstrap/main.py:3947` | require_uid |
| `GET` | `/s/{token}` | `share_page_html` | `functions/bootstrap/main.py:3967` | none (public) |
| `GET` | `/s/{token}/data` | `share_data` | `functions/bootstrap/main.py:3974` | none (public) |
| `GET` | `/s/{token}/card.png` | `share_card` | `functions/bootstrap/main.py:3986` | none (public) |
| `GET` | `/.well-known/assetlinks.json` | `assetlinks` | `functions/bootstrap/main.py:3997` | none (public) |
| `GET` | `/r/{code}` | `referral_landing` | `functions/bootstrap/main.py:4017` | none (public) |
| `GET` | `/r/{code}/card.png` | `referral_card` | `functions/bootstrap/main.py:4027` | none (public) |
| `GET` | `/referral` | `referral_info` | `functions/bootstrap/main.py:4036` | require_uid |
| `POST` | `/referral/redeem` | `referral_redeem` | `functions/bootstrap/main.py:4048` | require_uid |
| `POST` | `/block` | `block_user` | `functions/bootstrap/main.py:4066` | require_uid |
| `GET` | `/instagram/auth-url` | `instagram_auth_url` | `functions/bootstrap/main.py:4108` | _require_meta_integrations + require_uid |
| `POST` | `/instagram/connect` | `instagram_connect` | `functions/bootstrap/main.py:4123` | _require_meta_integrations + require_uid |
| `POST` | `/instagram/disconnect` | `instagram_disconnect` | `functions/bootstrap/main.py:4139` | _require_meta_integrations + require_uid |
| `GET` | `/instagram/signin-auth-url` | `instagram_signin_auth_url` | `functions/bootstrap/main.py:4150` | _require_meta_integrations |
| `POST` | `/instagram/signin` | `instagram_signin` | `functions/bootstrap/main.py:4167` | _require_meta_integrations |
| `POST` | `/auth/email-exists` | `auth_email_exists` | `functions/bootstrap/main.py:4185` | none (public) |
| `GET` | `/google/auth-url` | `google_auth_url` | `functions/bootstrap/main.py:4214` | require_uid |
| `POST` | `/google/connect` | `google_connect` | `functions/bootstrap/main.py:4230` | require_uid |
| `POST` | `/google/disconnect` | `google_disconnect` | `functions/bootstrap/main.py:4247` | require_uid |
| `GET` | `/google/status` | `google_status` | `functions/bootstrap/main.py:4258` | require_uid |
| `GET` | `/admin` | `admin_dashboard` | `functions/bootstrap/main.py:4266` | none (public) |
| `GET` | `/admin/provider-spend` | `admin_provider_spend` | `functions/bootstrap/main.py:4283` | require_admin_password |
| `GET` | `/admin/feature-flags` | `admin_feature_flags` | `functions/bootstrap/main.py:4296` | require_admin_password |
| `GET` | `/admin/vendors` | `admin_vendors` | `functions/bootstrap/main.py:4305` | require_admin_password |
| `POST` | `/admin/vendor-spend` | `admin_vendor_spend_record` | `functions/bootstrap/main.py:4318` | require_admin_password |
| `GET` | `/admin/users` | `admin_users` | `functions/bootstrap/main.py:4335` | require_admin_password |
| `GET` | `/admin/users/{uid}` | `admin_user_detail` | `functions/bootstrap/main.py:4345` | require_admin_password |
| `GET` | `/admin/users/{uid}/full` | `admin_user_full_detail` | `functions/bootstrap/main.py:4357` | require_admin_password |
| `GET` | `/admin/archived-accounts/{uid}` | `admin_archived_account_detail` | `functions/bootstrap/main.py:4373` | require_admin_password |
| `GET` | `/admin/knowledge-archives/{uid}` | `admin_knowledge_archive_list` | `functions/bootstrap/main.py:4392` | require_admin_password |
| `GET` | `/admin/knowledge-archives/{uid}/{archive_id}` | `admin_knowledge_archive_detail` | `functions/bootstrap/main.py:4409` | require_admin_password |
| `GET` | `/admin/media-url` | `admin_media_url` | `functions/bootstrap/main.py:4428` | require_admin_password |
| `GET` | `/admin/users/{uid}/credits` | `admin_user_credits` | `functions/bootstrap/main.py:4447` | require_admin_password |
| `GET` | `/admin/persona-changes` | `admin_persona_changes` | `functions/bootstrap/main.py:4460` | require_admin_password |
| `POST` | `/admin/persona-changes/{proposal_id}/approve` | `admin_persona_change_approve` | `functions/bootstrap/main.py:4475` | require_admin_password |
| `POST` | `/admin/persona-changes/{proposal_id}/reject` | `admin_persona_change_reject` | `functions/bootstrap/main.py:4491` | require_admin_password |
| `POST` | `/wiki/promote` | `wiki_promote` | `functions/bootstrap/main.py:4517` | require_uid |
| `GET` | `/wiki/ai-view` | `wiki_ai_view` | `functions/bootstrap/main.py:4645` | require_uid |
| `PUT` | `/wiki/photo-note` | `wiki_photo_note` | `functions/bootstrap/main.py:4666` | require_uid |
| `POST` | `/wiki/photo-hide` | `wiki_photo_hide` | `functions/bootstrap/main.py:4684` | require_uid |
| `POST` | `/wiki/photo-publish` | `wiki_photo_publish` | `functions/bootstrap/main.py:4702` | require_uid |
| `POST` | `/wiki/reset` | `wiki_reset` | `functions/bootstrap/main.py:4724` | require_uid |
| `GET` | `/usage` | `token_usage` | `functions/bootstrap/main.py:4780` | require_uid_and_dev_flag |
| `POST` | `/usage/reset-real-money` | `usage_reset_real_money` | `functions/bootstrap/main.py:4805` | require_dev |
| `POST` | `/credits/topup` | `credits_topup` | `functions/bootstrap/main.py:4816` | require_uid_and_dev_flag |
| `POST` | `/dev/verify` | `dev_verify` | `functions/bootstrap/main.py:4853` | require_uid |
| `POST` | `/webhooks/revenuecat` | `revenuecat_webhook` | `functions/bootstrap/main.py:4884` | require_revenuecat |
| `POST` | `/internal/storage/image-finalized` | `storage_image_finalized` | `functions/bootstrap/main.py:4908` | none (public) |
| `POST` | `/billing/sync` | `billing_sync` | `functions/bootstrap/main.py:4980` | require_uid_and_dev_flag |
| `POST` | `/dev/test-upgrade` | `dev_test_upgrade` | `functions/bootstrap/main.py:5028` | require_dev |
| `POST` | `/feedback` | `submit_feedback` | `functions/bootstrap/main.py:5066` | require_uid |
| `POST` | `/feedback/submit` | `submit_feedback_submission` | `functions/bootstrap/main.py:5092` | require_uid |
| `GET` | `/admin/feedback` | `admin_list_feedback` | `functions/bootstrap/main.py:5121` | require_dev |
| `POST` | `/admin/feedback/{fid}` | `admin_set_feedback_status` | `functions/bootstrap/main.py:5141` | require_dev |
| `GET` | `/admin/feedback/media` | `admin_feedback_media` | `functions/bootstrap/main.py:5155` | require_dev |
| `GET` | `/voice/presets` | `voice_presets` | `functions/bootstrap/main.py:5171` | require_uid |
| `GET` | `/voice/engines` | `voice_engines` | `functions/bootstrap/main.py:5193` | require_uid |
| `POST` | `/voice/preference` | `set_voice_preference_endpoint` | `functions/bootstrap/main.py:5269` | require_uid |
| `GET` | `/voice/agent-cloud` | `get_voice_agent_cloud` | `functions/bootstrap/main.py:5353` | require_uid |
| `POST` | `/voice/agent-cloud` | `set_voice_agent_cloud` | `functions/bootstrap/main.py:5370` | require_uid |
| `GET` | `/brain/preference` | `get_brain_preference` | `functions/bootstrap/main.py:5395` | require_uid |
| `POST` | `/brain/preference` | `set_brain_preference` | `functions/bootstrap/main.py:5427` | require_uid |
| `GET` | `/voice/preview/{voice_name}` | `voice_preview_endpoint` | `functions/bootstrap/main.py:5455` | require_uid |
| `POST` | `/media/photos/{media_id}/primary` | `media_photos_set_primary` | `functions/bootstrap/main.py:5494` | require_uid |
| `POST` | `/media/photos/{media_id}/delete` | `media_photos_delete_permanent` | `functions/bootstrap/main.py:5512` | require_uid |
| `PUT` | `/media/photos/order` | `media_photos_reorder` | `functions/bootstrap/main.py:5537` | require_uid |
| `GET` | `/physical-attributes` | `physical_attributes_get` | `functions/bootstrap/main.py:5620` | require_uid |
| `POST` | `/physical-attributes/refresh` | `physical_attributes_refresh` | `functions/bootstrap/main.py:5637` | require_uid |
| `GET` | `/physical-attributes-report/{report_id}` | `physical_attributes_report` | `functions/bootstrap/main.py:5679` | require_uid |
| `GET` | `/physical-attributes/history` | `physical_attributes_history` | `functions/bootstrap/main.py:5713` | require_uid |
| `GET` | `/physical-attributes/schema` | `physical_attributes_schema` | `functions/bootstrap/main.py:5770` | require_uid |
| `POST` | `/physical-attributes/correct` | `physical_attributes_correct` | `functions/bootstrap/main.py:5814` | require_uid |
| `GET` | `/report/{report_type}/{report_id}` | `report_get` | `functions/bootstrap/main.py:5892` | require_uid |
| `POST` | `/report/{report_type}/{report_id}/correct` | `report_correct` | `functions/bootstrap/main.py:5914` | require_uid |
| `GET` | `/skill-runs` | `skill_runs_get` | `functions/bootstrap/main.py:5976` | require_uid |
| `GET` | `/completeness` | `completeness_get` | `functions/bootstrap/main.py:6002` | require_uid |
| `GET` | `/questionnaire` | `questionnaire_get` | `functions/bootstrap/main.py:6015` | require_uid |
| `POST` | `/notifications/token` | `notifications_register_token` | `functions/bootstrap/main.py:6030` | require_uid |
| `POST` | `/notifications/token/remove` | `notifications_unregister_token` | `functions/bootstrap/main.py:6044` | require_uid |
| `POST` | `/run-matching` | `run_matching` | `functions/bootstrap/main.py:6055` | require_adult_uid |
| `POST` | `/match/{match_id}/respond` | `match_respond` | `functions/bootstrap/main.py:6076` | require_adult_uid |
| `POST` | `/check-compatibility` | `check_compatibility` | `functions/bootstrap/main.py:6307` | require_adult_uid |
| `GET` | `/match/{match_id}` | `match_report` | `functions/bootstrap/main.py:6363` | require_adult_uid |

## Practice Date router — `practice_date.py` (prefix `/practice`)

_4 routes._

| Method | Path | Handler | Source | Auth dependency |
| --- | --- | --- | --- | --- |
| `POST` | `/practice/start` | `practice_start` | `functions/bootstrap/practice_date.py:136` | require_not_underage_uid + require_caller |
| `POST` | `/practice/chat` | `practice_chat` | `functions/bootstrap/practice_date.py:163` | require_not_underage_uid + require_caller |
| `POST` | `/practice/debrief` | `practice_debrief` | `functions/bootstrap/practice_date.py:222` | require_not_underage_uid + require_caller |
| `POST` | `/practice/voice/start` | `practice_voice_start` | `functions/bootstrap/practice_date.py:251` | require_not_underage_uid + require_caller |

## Date Simulation router — `date_sim.py`

_5 routes._

| Method | Path | Handler | Source | Auth dependency |
| --- | --- | --- | --- | --- |
| `GET` | `/date-sim/estimate` | `date_sim_estimate` | `functions/bootstrap/date_sim.py:756` | require_caller |
| `POST` | `/date-sim` | `date_sim` | `functions/bootstrap/date_sim.py:787` | require_not_underage_uid + require_caller |
| `POST` | `/date-sim/{sim_id}/stop` | `date_sim_stop` | `functions/bootstrap/date_sim.py:838` | require_caller |
| `DELETE` | `/date-sim/pair/{other_uid}` | `date_sim_reset` | `functions/bootstrap/date_sim.py:856` | require_caller |
| `POST` | `/date-sim/{sim_id}/continue` | `date_sim_continue` | `functions/bootstrap/date_sim.py:872` | require_not_underage_uid + require_caller |

## Taste Match router — `taste_match.py`

_3 routes._

| Method | Path | Handler | Source | Auth dependency |
| --- | --- | --- | --- | --- |
| `POST` | `/taste/pair` | `taste_pair` | `functions/bootstrap/taste_match.py:660` | require_not_underage_uid + require_caller |
| `GET` | `/taste/demo` | `taste_demo_page` | `functions/bootstrap/taste_match.py:682` | none (public) |
| `GET` | `/taste/demo/pair` | `taste_demo_pair` | `functions/bootstrap/taste_match.py:688` | none (public) |

## Appearance router — `routes/appearance.py`

_7 routes._

| Method | Path | Handler | Source | Auth dependency |
| --- | --- | --- | --- | --- |
| `POST` | `/appearance/report` | `appearance_report_run` | `functions/bootstrap/routes/appearance.py:64` | require_uid |
| `GET` | `/appearance/report/{report_id}` | `appearance_report_get` | `functions/bootstrap/routes/appearance.py:130` | require_uid |
| `GET` | `/appearance/history` | `appearance_history_get` | `functions/bootstrap/routes/appearance.py:145` | require_uid |
| `GET` | `/appearance/coverage` | `appearance_coverage_get` | `functions/bootstrap/routes/appearance.py:157` | require_uid |
| `GET` | `/appearance/eligibility` | `appearance_eligibility_get` | `functions/bootstrap/routes/appearance.py:167` | require_uid |
| `POST` | `/appearance/finding/correct` | `appearance_finding_correct` | `functions/bootstrap/routes/appearance.py:179` | require_uid |
| `POST` | `/appearance/card/hidden` | `appearance_card_hidden_set` | `functions/bootstrap/routes/appearance.py:203` | require_uid |

## Cron router — `routes/cron.py`

_14 routes._

| Method | Path | Handler | Source | Auth dependency |
| --- | --- | --- | --- | --- |
| `POST` | `/cron/purge-deleted` | `cron_purge_deleted` | `functions/bootstrap/routes/cron.py:60` | require_cron |
| `POST` | `/cron/match` | `cron_match` | `functions/bootstrap/routes/cron.py:69` | require_cron |
| `POST` | `/cron/ingest-backfill` | `cron_ingest_backfill` | `functions/bootstrap/routes/cron.py:75` | require_cron |
| `POST` | `/cron/google-sync` | `cron_google_sync` | `functions/bootstrap/routes/cron.py:82` | require_cron |
| `POST` | `/cron/physical-attributes-backfill` | `cron_physical_attributes_backfill` | `functions/bootstrap/routes/cron.py:95` | require_cron |
| `POST` | `/cron/photo-tags-backfill` | `cron_photo_tags_backfill` | `functions/bootstrap/routes/cron.py:104` | require_cron |
| `POST` | `/cron/usable-for-body-resync` | `cron_usable_for_body_resync` | `functions/bootstrap/routes/cron.py:117` | require_cron |
| `POST` | `/cron/skill-backfill` | `cron_skill_backfill` | `functions/bootstrap/routes/cron.py:128` | require_cron |
| `POST` | `/cron/completeness-backfill` | `cron_completeness_backfill` | `functions/bootstrap/routes/cron.py:136` | require_cron |
| `POST` | `/cron/reengage` | `cron_reengage` | `functions/bootstrap/routes/cron.py:144` | require_cron |
| `POST` | `/cron/lint` | `cron_lint` | `functions/bootstrap/routes/cron.py:154` | require_cron |
| `POST` | `/cron/persona-evolution` | `cron_persona_evolution` | `functions/bootstrap/routes/cron.py:167` | require_cron |
| `POST` | `/cron/persona-snapshot` | `cron_persona_snapshot` | `functions/bootstrap/routes/cron.py:178` | require_cron |
| `POST` | `/cron/image-variants-backfill` | `cron_image_variants_backfill` | `functions/bootstrap/routes/cron.py:192` | require_cron |

## Media router — `routes/media.py`

_8 routes._

| Method | Path | Handler | Source | Auth dependency |
| --- | --- | --- | --- | --- |
| `POST` | `/media` | `register_media` | `functions/bootstrap/routes/media.py:104` | require_uid |
| `GET` | `/media/photos` | `media_photos_list` | `functions/bootstrap/routes/media.py:200` | require_uid |
| `POST` | `/media/photos` | `media_photos_add` | `functions/bootstrap/routes/media.py:206` | require_uid |
| `POST` | `/media/photos/batch` | `media_photos_add_batch` | `functions/bootstrap/routes/media.py:230` | require_uid |
| `POST` | `/media/photos/{media_id}/remove` | `media_photos_remove` | `functions/bootstrap/routes/media.py:265` | require_uid |
| `POST` | `/media/photos/{media_id}/primary` | `media_photos_set_primary` | `functions/bootstrap/routes/media.py:284` | require_uid |
| `POST` | `/media/photos/{media_id}/delete` | `media_photos_delete_permanent` | `functions/bootstrap/routes/media.py:300` | require_uid |
| `PUT` | `/media/photos/order` | `media_photos_reorder` | `functions/bootstrap/routes/media.py:319` | require_uid |

## Profile router — `routes/profile.py`

_9 routes._

| Method | Path | Handler | Source | Auth dependency |
| --- | --- | --- | --- | --- |
| `POST` | `/profile/share` | `profile_share` | `functions/bootstrap/routes/profile.py:54` | require_adult_uid |
| `PUT` | `/profile/preferences` | `profile_preferences_save` | `functions/bootstrap/routes/profile.py:76` | require_uid |
| `GET` | `/profile/public-text` | `profile_public_text` | `functions/bootstrap/routes/profile.py:98` | require_uid |
| `PUT` | `/profile/public-text` | `profile_public_text_save` | `functions/bootstrap/routes/profile.py:106` | require_uid |
| `GET` | `/profile/proposals` | `profile_proposals` | `functions/bootstrap/routes/profile.py:126` | require_uid |
| `POST` | `/profile/proposals/{page_id}/changes/{change_id}/apply` | `profile_change_apply` | `functions/bootstrap/routes/profile.py:139` | require_uid |
| `POST` | `/profile/proposals/{page_id}/changes/{change_id}/dismiss` | `profile_change_dismiss` | `functions/bootstrap/routes/profile.py:153` | require_uid |
| `POST` | `/profile/proposals/{page_id}/apply` | `profile_proposal_apply` | `functions/bootstrap/routes/profile.py:167` | require_uid |
| `POST` | `/profile/proposals/{page_id}/dismiss` | `profile_proposal_dismiss` | `functions/bootstrap/routes/profile.py:180` | require_uid |

## Story router — `routes/story.py`

_13 routes._

| Method | Path | Handler | Source | Auth dependency |
| --- | --- | --- | --- | --- |
| `GET` | `/story` | `story_get` | `functions/bootstrap/routes/story.py:63` | require_uid |
| `GET` | `/story/ai-notes` | `story_ai_notes` | `functions/bootstrap/routes/story.py:72` | require_uid |
| `PUT` | `/story/section` | `story_save_section` | `functions/bootstrap/routes/story.py:81` | require_uid |
| `POST` | `/story/section/visibility` | `story_set_visibility` | `functions/bootstrap/routes/story.py:98` | require_uid |
| `POST` | `/story/edit` | `story_edit` | `functions/bootstrap/routes/story.py:111` | require_uid |
| `POST` | `/story/section/remove` | `story_remove_section` | `functions/bootstrap/routes/story.py:130` | require_uid |
| `GET` | `/story/section/{page_id}/versions` | `story_section_versions` | `functions/bootstrap/routes/story.py:145` | require_uid |
| `GET` | `/story/section/{page_id}/versions/{version_id}` | `story_section_version` | `functions/bootstrap/routes/story.py:155` | require_uid |
| `POST` | `/story/section/revert` | `story_section_revert` | `functions/bootstrap/routes/story.py:168` | require_uid |
| `GET` | `/story/section/{page_id}/provenance` | `story_section_provenance` | `functions/bootstrap/routes/story.py:182` | require_uid |
| `GET` | `/story/career-timeline` | `story_career_timeline` | `functions/bootstrap/routes/story.py:199` | require_uid |
| `POST` | `/story/career-timeline/refresh` | `story_career_timeline_refresh` | `functions/bootstrap/routes/story.py:210` | require_uid |
| `POST` | `/story/linkedin` | `story_set_linkedin` | `functions/bootstrap/routes/story.py:219` | require_uid |

## MCP sub-app — `mcp_server.py` (Starlette, mounted at `/mcp`)

`main.py` mounts this Starlette sub-app at `/mcp` (`main.py:661`). It is part of the HTTP surface but is not a FastAPI `APIRouter`. Every route is additionally dark behind the `mcp_server` feature flag; when the flag is off the OAuth/approval handlers return `503`.

_10 routes plus one catch-all mount._

| Method | Path | Handler | Source | Auth dependency |
| --- | --- | --- | --- | --- |
| `POST` | `/mcp/oauth/device_authorization` | `device_authorization` | `functions/bootstrap/mcp_server.py` | none (public, OAuth device grant) |
| `POST` | `/mcp/oauth/token` | `token_endpoint` | `functions/bootstrap/mcp_server.py` | none (public, OAuth device grant) |
| `POST` | `/mcp/oauth/revoke` | `revoke_endpoint` | `functions/bootstrap/mcp_server.py` | none (public, RFC 7009 revocation) |
| `GET` | `/mcp/.well-known/oauth-authorization-server` | `as_metadata` | `functions/bootstrap/mcp_server.py` | none (public) |
| `GET` | `/mcp/.well-known/oauth-protected-resource` | `prm_metadata` | `functions/bootstrap/mcp_server.py` | none (public) |
| `GET` | `/mcp/connect` | `connect_page` | `functions/bootstrap/mcp_server.py` | none (public) |
| `POST` | `/mcp/connect/approve` | `approve_endpoint` | `functions/bootstrap/mcp_server.py` | Firebase ID token (`_firebase_uid`) |
| `GET` | `/mcp/connect/pending` | `pending_endpoint` | `functions/bootstrap/mcp_server.py` | Firebase ID token (`_firebase_uid`) |
| `GET` | `/mcp/connect/tokens` | `tokens_endpoint` | `functions/bootstrap/mcp_server.py` | Firebase ID token (`_firebase_uid`) |
| `POST` | `/mcp/connect/tokens/revoke` | `revoke_connection_endpoint` | `functions/bootstrap/mcp_server.py` | Firebase ID token (`_firebase_uid`) |
| `*` | `/mcp` | catch-all MCP streamable-HTTP endpoint | `functions/bootstrap/mcp_server.py` | Opaque Ayma MCP Bearer access token (`_McpAuthASGI`) + feature flag |

## Notes

- `routes/media.py` and `main.py` both define `POST /media/photos/{media_id}/primary`, `POST /media/photos/{media_id}/delete` and `PUT /media/photos/order` (handlers `media_photos_set_primary`, `media_photos_delete_permanent`, `media_photos_reorder`). Both definitions are listed here because both exist in the source; the router-registered copies are added first via `include_router`, so they match first.
- `/health`, `/welcome/token`, `/s/*`, `/r/*`, `/.well-known/assetlinks.json`, `/taste/demo*`, `/auth/email-exists` and the MCP OAuth metadata/device endpoints are intentionally public; `/internal/storage/image-finalized` authenticates a Pub/Sub OIDC token inside the handler; `/webhooks/revenuecat` and `/cron/*` use shared-secret header dependencies.
- The backend also mounts the MCP ASGI app (`app.mount("/mcp", ...)`) and adds the `RateLimiter` middleware; neither is a FastAPI route.

## Totals

- FastAPI routes: **188**
- MCP sub-app routes (including the catch-all mount): **11**
- Total HTTP routes/endpoints (FastAPI + MCP): **199**
