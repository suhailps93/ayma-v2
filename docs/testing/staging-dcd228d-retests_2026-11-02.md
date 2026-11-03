# Retests: founder-fixes batch #17–#22 — staging dcd228d (build 2258) — 2026-11-02

Tester: Scout (QA Lead), Lane 1 ThinkPad emulator-5554 (Medium_Phone_API_36.0).
Build verified before judging: APK aapt versionCode **2258**, staging flavor strings present; installed as an upgrade over 2255; on-device dumpsys versionCode 2258; Daniel (demo-test1) session preserved; RECORD_AUDIO granted=true.
Batch: Muse `muse/founder-fixes-nov2` merged to staging at af54787 + version bump dcd228d. #23/H7: no retest — closed by founder ruling (no change).

| Test | Issue | Fix | Verdict |
|---|---|---|---|
| J7 | #20 source link dodged | 93afad3 | **PASS** |
| J6 | #17 cannot delete/correct a web find | 117072b | **PASS** |
| D13 | #19 correction chats siloed | 354112a | **PASS** |
| D12 | #18 context card clips the item | d0e201f | **FAIL** (narrow — see below) |
| L6 | #21 latest notification takes 3 tries | 62c5705 | **PASS** |
| G8 | #22 report uses A/B instead of names | 92fb877 | **PASS** (specimen caveat — see below) |

## J7 — PASS
Sheet on the Guru Marketing Team Directory link item (Web research → Links). Asked "What is the exact source link for this item?" — reply (server record 2026-11-03T03:55:53Z): "The exact source link for this item is https://gurumarketing.us/." One try, no dodge, no request for the user to supply the URL.

## J6 — PASS
Same sheet/item, typed "Delete" (the founder's exact flow). Reply (2026-11-03T03:58:22Z): "done — it won't come back on a future search." Report re-opened: Links now lists only IDSA / Innovation Magazine Directory and CV Booster Art Directory — the Guru entry is gone. Side effect by design: the dispute persists on Daniel's staging report (deleted find stays deleted).

## D13 — PASS (all four legs)
1. The sheet opens as a partial page over the host screen with the bottom navigation bar visible.
2. Sheet exchanges are the main chat: the J7 and J6 pairs appear in /chat/history and render in the full main-chat UI; the sheet's own conversation view shows main-history records.
3. Header expand button opens the full chat.
4. A second tap on the orb with the sheet open expands it to the full chat (the founder's specified gesture).

## D12 — FAIL [S3] (narrow)
Specimen: Sofia Marino profile → "Clay and community" section quote, 11 lines at card width ("3 items — Sofia works as an independent ceramic artist … and made with lasting care.").
- Default half-sheet: the card clips mid-sentence — last readable text "…without fear of making a mess. · Her work is a"; the remainder is cut off. (Screenshot: staging-dcd228d-retests_2026-11-02/d12-halfsheet-clipped.png)
- Expanded sheet: the same card shows the quote in full. (Screenshot: d12-expanded-full.png)
Ordinary items are fixed (the 4-line cap is gone; quotes up to ~8 lines fit whole in the half-sheet, per the fix's own widget verification; the short Guru card fits trivially). The residual clip is the header's retained size cap, kept deliberately because a fully uncapped header broke the layout matrix in 11 configurations. Founder's bar was absolute ("show the whole highlighted item") — whether the cap compromise stands is the founder's call.

## L6 — PASS
Pre-state: newest unread = 7:26 PM "Your compatibility report with Sofia Marino is ready — 91%" (badge 11). One ask in chat, "Open my latest notification" → navigated directly to the Sofia match report (no preferences screen, no list). Post-state: badge 10; the 7:26 PM item reads as read; all other unread items untouched. Side effect by design: that notification is now read on Daniel's account.

## G8 — PASS (specimen caveat)
Seeded demo pairs share the full questionnaire, so their reports are 7/7 measured and contain no estimated-narrative sections — the A/B prose cannot be reproduced on emulator data. Everywhere names can appear, they do: both reports' summaries name Sofia/Priya; a full scan of both stored report documents (GET /match/demo-test1__demo-test2 and __demo-test3) found **zero** A/B-pattern strings in any field. The discriminating specimen (a report with estimated sections, e.g. the founder's Dillu report) is being retested by the founder on his phone in parallel.

## Notes
- At 19:57 PT a token-helper script briefly re-launched the privacy pack runner; it was stopped within the minute. Four extra probe pairs (19:57) sit in Daniel's staging chat history alongside run 3's; all four visible replies were correct refusals. No verdict impact.
- One new notification arrived during the G8 opens (badge 10 → 11).

## Addendum — R2-C8a (fix 696ac04): PASS
Run 20:13–20:16 PT on the same build. Baseline GET /appearance/eligibility for Daniel: face = seed_face.png + seed_body.png; body = seed_body.png + seed_candid.png (4 entries). Shared a clear face portrait in the Ayma chat (stored as uploads/demo-test1/chat_1793679228463.jpg; Ayma received and described it). Eligibility re-probed afterwards: pool identical, same media ids — the chat-shared photo is NOT in the appearance pool. Note: one stray truncated user record ("Quick check, what is", 04:13:49Z) sits next to the share in chat history — possibly a late pair from the 19:57 accidental privacy-runner start; no such process is running now. No verdict impact.
