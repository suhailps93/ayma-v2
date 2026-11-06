# Route Test Coverage Analysis

Generated from docs/API_INVENTORY.md


## Summary

**Overall Coverage: 182/199 (91.5%)**


| Router | Tested | Total | Coverage | Status |
|--------|--------|-------|----------|--------|
| date_sim.py | 2 | 5 | 40.0% | ❌ Low |
| main.py | 111 | 125 | 88.8% | ⚠️  Partial |
| taste_match.py | 3 | 3 | 100.0% | ✅ Complete |
| practice_date.py | 4 | 4 | 100.0% | ✅ Complete |
| mcp_server.py | 11 | 11 | 100.0% | ✅ Complete |
| routes/appearance.py | 7 | 7 | 100.0% | ✅ Complete |
| routes/cron.py | 14 | 14 | 100.0% | ✅ Complete |
| routes/media.py | 8 | 8 | 100.0% | ✅ Complete |
| routes/profile.py | 9 | 9 | 100.0% | ✅ Complete |
| routes/story.py | 13 | 13 | 100.0% | ✅ Complete |


---


## main.py

**Coverage: 111/125 (88.8%)**


| Method | Path | Handler | Tested | Test Files |
|--------|------|---------|--------|------------|
| GET | `/health` | `health` | ✅ | test_agent.py, test_agent_keepalive.py, test_app_control.py, test_biometric_consent.py, test_date_sim.py, test_health.py, test_profile_manual.py, test_wiki_lint.py, test_wiki_lint_batch.py |
| POST | `/bootstrap` | `bootstrap` | ✅ | test_account_endpoints.py, test_age_gate.py, test_agent.py, test_agent_wake.py, test_app_registry.py, test_biometric_consent.py, test_bootstrap.py, test_context_parity.py, test_gemini_tools.py, test_llm_call_site_coverage.py, test_voice_agent_cloud.py, test_voice_dispatch_fallback.py |
| POST | `/onboarding/complete` | `onboarding_complete` | ✅ | test_bootstrap.py, test_reverse_image_search.py |
| POST | `/welcome/token` | `welcome_token` | ✅ | test_bootstrap.py, test_voice_dispatch_fallback.py |
| POST | `/chat` | `chat` | ✅ | test_account_ops.py, test_admin_dashboard.py, test_age_gate.py, test_agent.py, test_ai_assessment.py, test_app_control.py, test_app_registry.py, test_appearance.py, test_appearance_endpoints.py, test_async_voice.py, test_auto_analysis.py, test_body_report.py, test_bug_reports_ops.py, test_career_timeline.py, test_chat.py, test_chat_history.py, test_clean_language_guardrail.py, test_completeness.py, test_config.py, test_context_ab_replay.py, test_context_opt.py, test_context_parity.py, test_date_sim.py, test_deep_dive.py, test_demo_account_overrides.py, test_dm_assist.py, test_face_report.py, test_fact_source.py, test_feature_flags.py, test_feedback_endpoints.py, test_feedback_ops.py, test_gemini_tools.py, test_generate_image_skill.py, test_guided_tour.py, test_image_variants.py, test_inference_routing.py, test_knowledge_wipe.py, test_llm_call_site_coverage.py, test_llm_provider.py, test_matching_endpoints.py, test_mcp_tools.py, test_media.py, test_monitoring.py, test_notifications_dispatch.py, test_notifications_triggers.py, test_open_weights_context_cap.py, test_open_weights_provider.py, test_photo_edit_skill.py, test_photo_notes.py, test_photo_pipeline.py, test_practice_date.py, test_profile_manual.py, test_prompt.py, test_public_profile.py, test_questionnaire_skill.py, test_ratelimit.py, test_recall.py, test_reengagement.py, test_report_adapters.py, test_report_blocks.py, test_report_bug_skill.py, test_report_endpoints.py, test_report_hub.py, test_rerun_web_research.py, test_set_profile_field.py, test_set_voice_preference.py, test_shared_photo_verify.py, test_skills.py, test_story.py, test_story_manage_skill.py, test_story_split.py, test_taste_backfill.py, test_token_ledger.py, test_tokencap_finalize.py, test_usage_endpoint.py, test_voice_catalog.py, test_voice_hot_swap.py, test_wiki_ai_view.py, test_wiki_ingest.py, test_wiki_photo_actions.py, test_world_state.py |
| POST | `/chat/stream` | `chat_stream` | ✅ | test_chat.py, test_tokencap_finalize.py |
| POST | `/post-turn` | `post_turn` | ✅ | test_chat.py, test_dm_ingest.py, test_inference_routing.py, test_persist_raw_turns.py, test_post_turn.py, test_tokencap_finalize.py |
| GET | `/chat/history` | `chat_history_page` | ✅ | test_chat.py, test_ratelimit.py |
| POST | `/voice/context` | `set_voice_context` | ✅ | test_app_control.py, test_voice_context_endpoint.py |
| DELETE | `/voice/context` | `clear_voice_context` | ✅ | test_app_control.py, test_voice_context_endpoint.py |
| POST | `/voice/async` | `voice_async` | ✅ | test_async_voice.py |
| GET | `/verification/status` | `verification_status` | ✅ | test_biometric_consent.py, test_verification.py |
| POST | `/verification/selfie` | `verification_selfie` | ✅ | test_biometric_consent.py, test_verification.py |
| POST | `/account/delete` | `account_delete` | ✅ | test_account_endpoints.py |
| POST | `/account/recover` | `account_recover` | ✅ | test_account_endpoints.py, test_account_purge.py, test_age_gate.py |
| GET | `/biometric-consent` | `biometric_consent_status` | ✅ | test_app_control.py, test_app_registry.py, test_biometric_consent.py |
| POST | `/biometric-consent` | `biometric_consent_accept` | ✅ | test_app_control.py, test_app_registry.py, test_biometric_consent.py |
| POST | `/biometric-consent/withdraw` | `biometric_consent_withdraw` | ✅ | test_biometric_consent.py |
| POST | `/age-gate/declare` | `age_gate_declare` | ✅ | test_age_gate.py, test_biometric_consent.py |
| GET | `/explore` | `explore` | ✅ | test_age_gate.py, test_agent.py, test_app_control.py, test_app_registry.py, test_chat.py, test_deep_dive_social.py, test_dm_outreach.py, test_explore.py, test_explore_accent_prefs.py, test_explore_hides_fixtures.py, test_feedback_endpoints.py, test_guided_tour.py, test_knowledge_wipe.py, test_matching_endpoints.py, test_report_adapters.py, test_report_endpoints.py, test_report_hub.py, test_skills.py, test_tool_labels.py, test_voice_actions.py, test_voice_actions_eval.py, test_voice_context_endpoint.py, test_world_state.py |
| GET | `/explore/profile/{other_uid}` | `explore_profile` | ✅ | test_report_endpoints.py |
| POST | `/deep-dive` | `deep_dive_endpoint` | ✅ | test_auto_analysis.py, test_chat.py, test_deep_dive.py, test_report_blocks.py, test_report_endpoints.py, test_wiki_ai_view.py |
| GET | `/deep-dive-report/{report_id}` | `deep_dive_report` | ✅ | test_deep_dive.py, test_report_endpoints.py, test_report_hub.py |
| GET | `/deep-dive/mine` | `deep_dive_mine` | ✅ | test_deep_dive.py |
| POST | `/deep-dive/{report_id}/facts/{fact_id}/dispute` | `deep_dive_dispute_fact` | ✅ | test_deep_dive.py |
| POST | `/deep-dive/{report_id}/correct` | `deep_dive_correct` | ✅ | test_deep_dive.py, test_report_hub.py |
| GET | `/web-search/photos/candidates` | `web_search_photo_candidates` | ✅ | test_reverse_image_search.py |
| POST | `/web-search/photos/rescan` | `web_search_photo_rescan` | ✅ | test_reverse_image_search.py |
| POST | `/web-search/photos/candidates/{candidate_id}/confirm` | `web_search_photo_confirm` | ✅ | test_reverse_image_search.py |
| POST | `/web-search/photos/candidates/{candidate_id}/reject` | `web_search_photo_reject` | ✅ | test_reverse_image_search.py |
| POST | `/face-report` | `face_report_endpoint` | ✅ | test_face_report.py |
| POST | `/body-report` | `body_report_endpoint` | ✅ | test_body_report.py |
| GET | `/skills/report/{kind}/{report_id}` | `skills_report` | ✅ | test_skill_memory.py |
| GET | `/skills/reports/{kind}` | `skills_reports` | ✅ | test_skill_memory.py |
| POST | `/profiles/mini` | `profiles_mini` | ✅ | test_public_profile.py |
| POST | `/explore/like` | `explore_like` | ❌ | - |
| POST | `/explore/unlike` | `explore_unlike` | ✅ | test_matching_endpoints.py |
| POST | `/explore/pass` | `explore_pass` | ✅ | test_explore.py, test_knowledge_wipe.py |
| POST | `/dm/{thread_id}/messages` | `dm_send` | ✅ | test_dm_ops.py, test_persona_snapshot.py, test_ratelimit.py |
| POST | `/dm/assist` | `dm_assist_endpoint` | ✅ | test_dm_assist.py |
| POST | `/dm/translate` | `dm_translate_endpoint` | ✅ | test_dm_translate.py |
| POST | `/share` | `share_create` | ✅ | test_matching_endpoints.py, test_router_split.py, test_share.py |
| POST | `/share/revoke` | `share_revoke` | ✅ | test_share.py |
| GET | `/s/{token}` | `share_page_html` | ❌ | - |
| GET | `/s/{token}/data` | `share_data` | ❌ | - |
| GET | `/s/{token}/card.png` | `share_card` | ❌ | - |
| GET | `/.well-known/assetlinks.json` | `assetlinks` | ✅ | test_share.py |
| GET | `/r/{code}` | `referral_landing` | ❌ | - |
| GET | `/r/{code}/card.png` | `referral_card` | ❌ | - |
| GET | `/referral` | `referral_info` | ✅ | test_referrals.py |
| POST | `/referral/redeem` | `referral_redeem` | ✅ | test_referrals.py |
| POST | `/block` | `block_user` | ✅ | test_matching_endpoints.py |
| GET | `/instagram/auth-url` | `instagram_auth_url` | ✅ | test_instagram.py |
| POST | `/instagram/connect` | `instagram_connect` | ✅ | test_instagram.py |
| POST | `/instagram/disconnect` | `instagram_disconnect` | ✅ | test_instagram.py |
| GET | `/instagram/signin-auth-url` | `instagram_signin_auth_url` | ✅ | test_instagram.py |
| POST | `/instagram/signin` | `instagram_signin` | ✅ | test_instagram.py |
| POST | `/auth/email-exists` | `auth_email_exists` | ✅ | test_auth_email_exists.py |
| GET | `/google/auth-url` | `google_auth_url` | ✅ | test_google_account.py |
| POST | `/google/connect` | `google_connect` | ✅ | test_google_account.py |
| POST | `/google/disconnect` | `google_disconnect` | ❌ | - |
| GET | `/google/status` | `google_status` | ❌ | - |
| GET | `/admin` | `admin_dashboard` | ✅ | test_admin.py, test_admin_dashboard.py, test_admin_lookup.py, test_feature_flags.py, test_feedback_endpoints.py, test_persona_evolution_endpoints.py, test_provider_spend.py, test_vendor_spend.py |
| GET | `/admin/provider-spend` | `admin_provider_spend` | ✅ | test_admin.py, test_provider_spend.py |
| GET | `/admin/feature-flags` | `admin_feature_flags` | ✅ | test_feature_flags.py |
| GET | `/admin/vendors` | `admin_vendors` | ✅ | test_vendor_spend.py |
| POST | `/admin/vendor-spend` | `admin_vendor_spend_record` | ✅ | test_vendor_spend.py |
| GET | `/admin/users` | `admin_users` | ✅ | test_admin.py, test_admin_dashboard.py, test_admin_lookup.py |
| GET | `/admin/users/{uid}` | `admin_user_detail` | ✅ | test_admin_dashboard.py |
| GET | `/admin/users/{uid}/full` | `admin_user_full_detail` | ❌ | - |
| GET | `/admin/archived-accounts/{uid}` | `admin_archived_account_detail` | ❌ | - |
| GET | `/admin/knowledge-archives/{uid}` | `admin_knowledge_archive_list` | ❌ | - |
| GET | `/admin/knowledge-archives/{uid}/{archive_id}` | `admin_knowledge_archive_detail` | ❌ | - |
| GET | `/admin/media-url` | `admin_media_url` | ✅ | test_admin_dashboard.py |
| GET | `/admin/users/{uid}/credits` | `admin_user_credits` | ✅ | test_admin_dashboard.py |
| GET | `/admin/persona-changes` | `admin_persona_changes` | ✅ | test_persona_evolution_endpoints.py |
| POST | `/admin/persona-changes/{proposal_id}/approve` | `admin_persona_change_approve` | ✅ | test_persona_evolution_endpoints.py |
| POST | `/admin/persona-changes/{proposal_id}/reject` | `admin_persona_change_reject` | ✅ | test_persona_evolution_endpoints.py |
| POST | `/wiki/promote` | `wiki_promote` | ✅ | test_skill_memory.py |
| GET | `/wiki/ai-view` | `wiki_ai_view` | ✅ | test_wiki_ai_view.py |
| PUT | `/wiki/photo-note` | `wiki_photo_note` | ✅ | test_wiki_photo_actions.py |
| POST | `/wiki/photo-hide` | `wiki_photo_hide` | ✅ | test_wiki_photo_actions.py |
| POST | `/wiki/photo-publish` | `wiki_photo_publish` | ✅ | test_wiki_photo_actions.py |
| POST | `/wiki/reset` | `wiki_reset` | ✅ | test_wiki_reset.py |
| GET | `/usage` | `token_usage` | ✅ | test_agent.py, test_app_registry.py, test_billing.py, test_inference_routing.py, test_knowledge_wipe.py, test_mcp_tools.py, test_token_ledger.py, test_usage_endpoint.py |
| POST | `/usage/reset-real-money` | `usage_reset_real_money` | ✅ | test_usage_endpoint.py |
| POST | `/credits/topup` | `credits_topup` | ✅ | test_usage_endpoint.py |
| POST | `/dev/verify` | `dev_verify` | ✅ | test_dev_flags.py |
| POST | `/webhooks/revenuecat` | `revenuecat_webhook` | ✅ | test_billing.py |
| POST | `/internal/storage/image-finalized` | `storage_image_finalized` | ✅ | test_image_variants.py |
| POST | `/billing/sync` | `billing_sync` | ✅ | test_billing.py |
| POST | `/dev/test-upgrade` | `dev_test_upgrade` | ✅ | test_billing.py |
| POST | `/feedback` | `submit_feedback` | ✅ | test_feedback_endpoints.py, test_feedback_ops.py, test_skills.py |
| POST | `/feedback/submit` | `submit_feedback_submission` | ✅ | test_feedback_endpoints.py |
| GET | `/admin/feedback` | `admin_list_feedback` | ✅ | test_feedback_endpoints.py |
| POST | `/admin/feedback/{fid}` | `admin_set_feedback_status` | ❌ | - |
| GET | `/admin/feedback/media` | `admin_feedback_media` | ❌ | - |
| GET | `/voice/presets` | `voice_presets` | ✅ | test_voice_presets_endpoint.py |
| GET | `/voice/engines` | `voice_engines` | ✅ | test_voice_engines_endpoint.py |
| POST | `/voice/preference` | `set_voice_preference_endpoint` | ✅ | test_voice_engines_endpoint.py |
| GET | `/voice/agent-cloud` | `get_voice_agent_cloud` | ✅ | test_voice_agent_cloud.py |
| POST | `/voice/agent-cloud` | `set_voice_agent_cloud` | ✅ | test_voice_agent_cloud.py |
| GET | `/brain/preference` | `get_brain_preference` | ✅ | test_brain_preference_endpoint.py |
| POST | `/brain/preference` | `set_brain_preference` | ✅ | test_brain_preference_endpoint.py |
| GET | `/voice/preview/{voice_name}` | `voice_preview_endpoint` | ✅ | test_voice_preview.py |
| POST | `/media/photos/{media_id}/primary` | `media_photos_set_primary` | ✅ | test_media.py, test_router_split.py |
| POST | `/media/photos/{media_id}/delete` | `media_photos_delete_permanent` | ✅ | test_media.py, test_router_split.py |
| PUT | `/media/photos/order` | `media_photos_reorder` | ✅ | test_router_split.py |
| GET | `/physical-attributes` | `physical_attributes_get` | ✅ | test_physical_attributes.py, test_router_split.py |
| POST | `/physical-attributes/refresh` | `physical_attributes_refresh` | ✅ | test_physical_attributes.py, test_skill_runs.py |
| GET | `/physical-attributes-report/{report_id}` | `physical_attributes_report` | ✅ | test_physical_attributes.py |
| GET | `/physical-attributes/history` | `physical_attributes_history` | ✅ | test_physical_attributes.py |
| GET | `/physical-attributes/schema` | `physical_attributes_schema` | ✅ | test_physical_attributes.py |
| POST | `/physical-attributes/correct` | `physical_attributes_correct` | ✅ | test_physical_attributes.py |
| GET | `/report/{report_type}/{report_id}` | `report_get` | ✅ | test_appearance_endpoints.py, test_report_endpoints.py |
| POST | `/report/{report_type}/{report_id}/correct` | `report_correct` | ✅ | test_report_endpoints.py |
| GET | `/skill-runs` | `skill_runs_get` | ✅ | test_skill_runs_endpoints.py |
| GET | `/completeness` | `completeness_get` | ✅ | test_completeness.py, test_router_split.py, test_wiki_ingest.py |
| GET | `/questionnaire` | `questionnaire_get` | ✅ | test_chat.py, test_completeness.py, test_match_report_cache.py, test_prompt.py, test_question_tree.py |
| POST | `/notifications/token` | `notifications_register_token` | ✅ | test_notifications_endpoints.py |
| POST | `/notifications/token/remove` | `notifications_unregister_token` | ✅ | test_notifications_endpoints.py |
| POST | `/run-matching` | `run_matching` | ✅ | test_age_gate.py, test_matching_endpoints.py |
| POST | `/match/{match_id}/respond` | `match_respond` | ✅ | test_matching_endpoints.py |
| POST | `/check-compatibility` | `check_compatibility` | ✅ | test_match_report_cache.py, test_matching_endpoints.py |
| GET | `/match/{match_id}` | `match_report` | ✅ | test_app_control.py, test_chat.py, test_matching_endpoints.py, test_report_endpoints.py, test_taste_match.py, test_tool_labels.py, test_world_state.py |


## practice_date.py

**Coverage: 4/4 (100.0%)**


| Method | Path | Handler | Tested | Test Files |
|--------|------|---------|--------|------------|
| POST | `/practice/start` | `practice_start` | ✅ | test_practice_date_endpoints.py |
| POST | `/practice/chat` | `practice_chat` | ✅ | test_practice_date_endpoints.py |
| POST | `/practice/debrief` | `practice_debrief` | ✅ | test_practice_date_endpoints.py |
| POST | `/practice/voice/start` | `practice_voice_start` | ✅ | test_practice_date_endpoints.py, test_voice_dispatch_fallback.py |


## date_sim.py

**Coverage: 2/5 (40.0%)**


| Method | Path | Handler | Tested | Test Files |
|--------|------|---------|--------|------------|
| GET | `/date-sim/estimate` | `date_sim_estimate` | ✅ | test_persona_snapshot.py |
| POST | `/date-sim` | `date_sim` | ✅ | test_agent.py, test_app_control.py, test_clean_language_guardrail.py, test_date_sim.py, test_persona_snapshot.py, test_voice_actions.py, test_world_state.py |
| POST | `/date-sim/{sim_id}/stop` | `date_sim_stop` | ❌ | - |
| DELETE | `/date-sim/pair/{other_uid}` | `date_sim_reset` | ❌ | - |
| POST | `/date-sim/{sim_id}/continue` | `date_sim_continue` | ❌ | - |


## taste_match.py

**Coverage: 3/3 (100.0%)**


| Method | Path | Handler | Tested | Test Files |
|--------|------|---------|--------|------------|
| POST | `/taste/pair` | `taste_pair` | ✅ | test_taste_match.py |
| GET | `/taste/demo` | `taste_demo_page` | ✅ | test_taste_match.py |
| GET | `/taste/demo/pair` | `taste_demo_pair` | ✅ | test_taste_match.py |


## routes/appearance.py

**Coverage: 7/7 (100.0%)**


| Method | Path | Handler | Tested | Test Files |
|--------|------|---------|--------|------------|
| POST | `/appearance/report` | `appearance_report_run` | ✅ | test_appearance.py, test_appearance_endpoints.py, test_router_split.py |
| GET | `/appearance/report/{report_id}` | `appearance_report_get` | ✅ | test_router_split.py |
| GET | `/appearance/history` | `appearance_history_get` | ✅ | test_appearance_endpoints.py, test_router_split.py |
| GET | `/appearance/coverage` | `appearance_coverage_get` | ✅ | test_appearance_endpoints.py, test_router_split.py |
| GET | `/appearance/eligibility` | `appearance_eligibility_get` | ✅ | test_router_split.py |
| POST | `/appearance/finding/correct` | `appearance_finding_correct` | ✅ | test_appearance_endpoints.py, test_router_split.py |
| POST | `/appearance/card/hidden` | `appearance_card_hidden_set` | ✅ | test_appearance_card_hidden.py, test_router_split.py |


## routes/cron.py

**Coverage: 14/14 (100.0%)**


| Method | Path | Handler | Tested | Test Files |
|--------|------|---------|--------|------------|
| POST | `/cron/purge-deleted` | `cron_purge_deleted` | ✅ | test_router_split.py |
| POST | `/cron/match` | `cron_match` | ✅ | test_router_split.py |
| POST | `/cron/ingest-backfill` | `cron_ingest_backfill` | ✅ | test_router_split.py |
| POST | `/cron/google-sync` | `cron_google_sync` | ✅ | test_router_split.py |
| POST | `/cron/physical-attributes-backfill` | `cron_physical_attributes_backfill` | ✅ | test_router_split.py |
| POST | `/cron/photo-tags-backfill` | `cron_photo_tags_backfill` | ✅ | test_appearance_endpoints.py, test_router_split.py |
| POST | `/cron/usable-for-body-resync` | `cron_usable_for_body_resync` | ✅ | test_appearance_endpoints.py, test_router_split.py |
| POST | `/cron/skill-backfill` | `cron_skill_backfill` | ✅ | test_router_split.py, test_skill_runs_endpoints.py |
| POST | `/cron/completeness-backfill` | `cron_completeness_backfill` | ✅ | test_completeness.py, test_router_split.py |
| POST | `/cron/reengage` | `cron_reengage` | ✅ | test_router_split.py |
| POST | `/cron/lint` | `cron_lint` | ✅ | test_cron_lint.py, test_router_split.py |
| POST | `/cron/persona-evolution` | `cron_persona_evolution` | ✅ | test_persona_evolution_endpoints.py, test_router_split.py |
| POST | `/cron/persona-snapshot` | `cron_persona_snapshot` | ✅ | test_router_split.py |
| POST | `/cron/image-variants-backfill` | `cron_image_variants_backfill` | ✅ | test_image_variants.py, test_router_split.py |


## routes/media.py

**Coverage: 8/8 (100.0%)**


| Method | Path | Handler | Tested | Test Files |
|--------|------|---------|--------|------------|
| POST | `/media` | `register_media` | ✅ | test_admin_dashboard.py, test_deep_dive_images.py, test_media.py, test_router_split.py |
| GET | `/media/photos` | `media_photos_list` | ✅ | test_media.py, test_router_split.py |
| POST | `/media/photos` | `media_photos_add` | ✅ | test_media.py, test_router_split.py |
| POST | `/media/photos/batch` | `media_photos_add_batch` | ✅ | test_media.py, test_router_split.py |
| POST | `/media/photos/{media_id}/remove` | `media_photos_remove` | ✅ | test_media.py, test_router_split.py |
| POST | `/media/photos/{media_id}/primary` | `media_photos_set_primary` | ✅ | test_media.py, test_router_split.py |
| POST | `/media/photos/{media_id}/delete` | `media_photos_delete_permanent` | ✅ | test_media.py, test_router_split.py |
| PUT | `/media/photos/order` | `media_photos_reorder` | ✅ | test_router_split.py |


## routes/profile.py

**Coverage: 9/9 (100.0%)**


| Method | Path | Handler | Tested | Test Files |
|--------|------|---------|--------|------------|
| POST | `/profile/share` | `profile_share` | ✅ | test_matching_endpoints.py, test_router_split.py |
| PUT | `/profile/preferences` | `profile_preferences_save` | ✅ | test_router_split.py, test_voice_context_endpoint.py |
| GET | `/profile/public-text` | `profile_public_text` | ✅ | test_mcp_tools.py, test_router_split.py |
| PUT | `/profile/public-text` | `profile_public_text_save` | ✅ | test_router_split.py |
| GET | `/profile/proposals` | `profile_proposals` | ✅ | test_router_split.py |
| POST | `/profile/proposals/{page_id}/changes/{change_id}/apply` | `profile_change_apply` | ✅ | test_router_split.py |
| POST | `/profile/proposals/{page_id}/changes/{change_id}/dismiss` | `profile_change_dismiss` | ✅ | test_router_split.py |
| POST | `/profile/proposals/{page_id}/apply` | `profile_proposal_apply` | ✅ | test_router_split.py |
| POST | `/profile/proposals/{page_id}/dismiss` | `profile_proposal_dismiss` | ✅ | test_router_split.py |


## routes/story.py

**Coverage: 13/13 (100.0%)**


| Method | Path | Handler | Tested | Test Files |
|--------|------|---------|--------|------------|
| GET | `/story` | `story_get` | ✅ | test_app_control.py, test_photo_edit_skill.py, test_report_endpoints.py, test_router_split.py, test_story_endpoints.py, test_story_manage_skill.py, test_timefmt.py |
| GET | `/story/ai-notes` | `story_ai_notes` | ✅ | test_report_adapters.py, test_report_hub.py, test_router_split.py |
| PUT | `/story/section` | `story_save_section` | ✅ | test_router_split.py, test_story_endpoints.py |
| POST | `/story/section/visibility` | `story_set_visibility` | ✅ | test_router_split.py |
| POST | `/story/edit` | `story_edit` | ✅ | test_ai_assessment.py, test_app_control.py, test_app_registry.py, test_chat.py, test_router_split.py |
| POST | `/story/section/remove` | `story_remove_section` | ✅ | test_router_split.py |
| GET | `/story/section/{page_id}/versions` | `story_section_versions` | ✅ | test_router_split.py |
| GET | `/story/section/{page_id}/versions/{version_id}` | `story_section_version` | ✅ | test_router_split.py |
| POST | `/story/section/revert` | `story_section_revert` | ✅ | test_router_split.py |
| GET | `/story/section/{page_id}/provenance` | `story_section_provenance` | ✅ | test_router_split.py |
| GET | `/story/career-timeline` | `story_career_timeline` | ✅ | test_router_split.py, test_story_endpoints.py |
| POST | `/story/career-timeline/refresh` | `story_career_timeline_refresh` | ✅ | test_router_split.py, test_story_endpoints.py |
| POST | `/story/linkedin` | `story_set_linkedin` | ✅ | test_router_split.py, test_story_endpoints.py |


## mcp_server.py

**Coverage: 11/11 (100.0%)**


| Method | Path | Handler | Tested | Test Files |
|--------|------|---------|--------|------------|
| POST | `/mcp/oauth/device_authorization` | `device_authorization` | ✅ | test_mcp_server.py |
| POST | `/mcp/oauth/token` | `token_endpoint` | ✅ | test_mcp_server.py |
| POST | `/mcp/oauth/revoke` | `revoke_endpoint` | ✅ | test_mcp_server.py |
| GET | `/mcp/.well-known/oauth-authorization-server` | `as_metadata` | ✅ | test_mcp_server.py |
| GET | `/mcp/.well-known/oauth-protected-resource` | `prm_metadata` | ✅ | test_mcp_server.py |
| GET | `/mcp/connect` | `connect_page` | ✅ | test_mcp_server.py |
| POST | `/mcp/connect/approve` | `approve_endpoint` | ✅ | test_mcp_server.py |
| GET | `/mcp/connect/pending` | `pending_endpoint` | ✅ | test_mcp_server.py |
| GET | `/mcp/connect/tokens` | `tokens_endpoint` | ✅ | test_mcp_server.py |
| POST | `/mcp/connect/tokens/revoke` | `revoke_connection_endpoint` | ✅ | test_mcp_server.py |
| * | `/mcp` | `catch-all` | ✅ | test_mcp_server.py |
