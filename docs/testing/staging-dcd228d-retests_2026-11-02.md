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

## Addendum 2 — J8 appearance re-run freshness (staging 9561d00, build 2262): PASS
Run 20:29–20:35 PT, build verified (aapt + dumpsys versionCode 2262). Baseline: current Appearance report created 2026-11-03T04:14:32Z; eligibility pool = seed_face/seed_body/seed_candid (4 entries). Added a new face photo to Daniel's profile grid (uploads/demo-test1/photo_1793680237719_0.jpg): it entered the eligibility pool as a Face entry (pool 4→5) and the grid showed 4 photos. Re-ran from the Appearance screen: the run sheet showed **Face analysis 3 selected including the new portrait** (screenshot: staging-dcd228d-retests_2026-11-02/j8-runsheet-face3.png); Body stayed 2. After Run analysis, the stored current report was **regenerated at 2026-11-03T04:33:01Z** — not a re-serve of the 04:14 report — FACE 7.3 / BODY 5.8, summary freshly generated (now includes the stated height line). Fixture restored afterwards: the added photo was deleted everywhere; eligibility is back to the 4-entry baseline.

## Addendum 3 — D14 + J7-natural (staging 1e26a13, build 2264)
Run 21:32–21:47 PT, build verified (aapt + dumpsys versionCode 2264). Specimen: Daniel's Web research report, IDSA / Innovation Magazine Directory link, stored source https://issuu.com/idsa.innovation/docs/innovation_fall18_issuu.
- D14 PASS (all legs): partial Ask Ayma sheet shows context card + composer only, NO history (before and after sending); the sheet-sent turn lands in main-chat history (server record 05:35:33Z); expanding to full shows the whole conversation including the sheet-sent turn and its URL reply.
- J7-natural FAIL [S3, narrow]: 8 of 9 asks return the exact stored URL. In the scoped sheet, all five phrasings pass — "where did you get this information from", "where's this from", "what's this based on", "who says that", "prove it" — and the same question twice in a row returns the URL both times. In main chat, "where's this from" resolves to the IDSA item and returns the URL. BUT main-chat "prove it" (two consecutive turns, after the URL was already given) answers the veracity challenge instead of re-grounding: "it's just a public search result… none of it is verified as actually being you yet" / "you're better off just telling me yourself" — no URL either time. The veracity answers are substantively correct (the report's own summary says unverified), but under the brief's every-phrasing-every-time bar the unscoped "prove it" leg misses. Founder decides whether the challenge-reading is acceptable.
Evidence: staging-dcd228d-retests_2026-11-02/d14-partial-sheet.png, d14-expanded-turn.png (also in this chat).

## Addendum 4 — J8 retest, HEIF specimen (build 2264 vs staging API rev 00124-8t7)
Run 21:48–21:58 PT. Specimen: a FRESH HEIF still (j8heif.heic, converted from the e2e faceB portrait with pillow-heif; the Oct-24 orphan was NOT used). Baseline: current report 2026-11-03T04:33:01Z, eligibility = 3 seed photos / 4 entries.
- Add: picker → HEIF selected → uploaded as uploads/demo-test1/photo_1793685085953_0.heic (.heic preserved); eligibility gained it as a Face entry (pool 4→5); profile grid shows it as photo 4 (visible after re-entering the profile; the strip does not live-refresh on return from the picker).
- Re-run: run sheet Face analysis = 3 selected INCLUDING the new HEIF portrait; Body 2 selected. Fresh report created 2026-11-03T05:54:06Z with regenerated attributes (hair color black→brown, height ~175→180) — not a re-serve. The Appearance page photo strip shows all 4 photos including the HEIF portrait; FACE detail 7.1/10.
- OBSERVATION (new, S3 candidate): the share-card COLLAGE at the top of the Appearance screen still renders the PREVIOUS run's photo set — its 4th tile is the white-V-neck specimen photo that was deleted-everywhere in the earlier J8 restore — instead of the new HEIF photo. Report content, attributes, and the page photo strip are all current; only the collage lags. A deleted-everywhere photo still rendering on the share card is worth a ruling.
- Restore: HEIF photo deleted everywhere; eligibility verified back to the exact seed baseline (4 entries).
Verdict: J8 PASS (auto-grid fix verified on the HEIF path — the October orphan failure mode does not reproduce for a freshly-added photo).
Evidence: staging-dcd228d-retests_2026-11-02/j8heif-runsheet.png, j8heif-card-photos.png (also in this chat).

## Addendum 5 — B12 + F3 + F9 retests (build 2266 / staging 5899fec)
Run 23:16–23:50 PT. Build verified: aapt versionCode 2266, on-device dumpsys 2266.

### B12 (wrong-password behavior) — FAIL [S2], split
- Existing account + wrong password (test1@gmail.com + WrongPass123, two separate submits, button center verified by uiautomator bounds): form STAYS on sign-in, never flips to create-account — the founder's original complaint is fixed. BUT no wrong-password error appears at all: no inline error, no snackbar, no spinner, across 45s+ of observation per attempt.
- Unknown email (nosuchuser-xyz123@example.com + password, submit + 55s wait): NO flip to sign-up either — the form sits inert, same as the wrong-password case.
- Control: correct password (Test123) signs in immediately, so the button and success path work; only failed-credential feedback is missing. Likely single root cause: failed sign-in attempts produce no UI feedback (the submit handler swallows the failure, or the email-exists oracle call stalls silently).
- Daniel's session restored after the run (signed back in as test1; chat history intact).
Evidence: staging-dcd228d-retests_2026-11-02/b12-wrongpw-noerror.png (this chat).

### F3 (Explore search) — PASS, all legs
- Baseline Everyone grid: Daniel (self), Sofia 91%, Priya 17%, Alexander 0%, + more.
- Query "someone who loves pottery and quiet mornings" via keyboard search key: thin pink progress bar shows during search; grid changes — Alexander removed (Daniel, Sofia, Priya remain).
- Query "loves pottery" via the field's magnifier icon: grid filters to exactly Daniel + Sofia (Priya, Alexander removed).
- Same query via Enter key (adb keyevent 66): grid stays filtered to Daniel + Sofia (typing alone does not filter, proven by the pre-submit screenshots).
- Clear (x): field back to placeholder, grid back to full baseline.
Evidence: staging-dcd228d-retests_2026-11-02/f3-filtered.png (this chat).

### F9 (Explore empty state) — PASS
- Gibberish "asdfghjk" via keyboard search: clean empty state "No one matches that yet." — no cards, no crash, no stale results. Cleared afterward; baseline grid restored.
Evidence: staging-dcd228d-retests_2026-11-02/f9-empty.png (this chat).

## Addendum 6 — 2267 four-fix batch + carried retests (staging e8e9420, build 2267)
Run ~00:00–01:04 PT Nov 3 (emulator clock). Build verified: pubspec 1.30.0+2267, aapt versionCode 2267, on-device dumpsys 2267. Staging tip e8e9420 (simtaste + P5 + tokencap + voice-opener batch + guided tour at 37cee79). Daniel signed in and restored at the end, history intact, badge 12, no accounts created, no fixture damage.

### P5 (Settings footer) — PASS
- Settings footer reads exactly "Version 1.30.0+2267 · staging" — version, build number, staging tag all present (2266 showed "Version 1.30.0" only).
Evidence: staging-dcd228d-retests_2026-11-02/2267-p5-footer.png.

### F3 (Explore search) — PASS (keyboard leg on 2267)
- Baseline Everyone grid matches 2266 (Daniel self, Sofia 91%, Priya 17%, Alexander 0%). Query "someone who loves pottery and quiet mornings" via keyboard search key: grid filters to Daniel + Sofia + Priya, Alexander removed — identical to the 2266 keyboard leg. (Magnifier-icon and Enter-key legs were proven on 2266; this batch does not touch Explore search code.)
Evidence: staging-dcd228d-retests_2026-11-02/2267-f3-filtered.png.

### F9 (Explore empty state) — PASS (retry; first attempt ANR'd, see incidents)
- After the reinstall + re-sign-in: gibberish "asdfghjk" via keyboard search → clean "No one matches that yet." empty state, no cards, no crash. Clear (x) restores the full baseline grid.
Evidence: staging-dcd228d-retests_2026-11-02/2267-f9-empty.png.

### B12 (wrong-password behavior) — FAIL [S2], split (same overall as 2266, one leg improved)
- Known email + wrong password (test1@gmail.com + WrongPass123, 12 chars screenshot-verified): form STAYS on sign-in (never flips to create-account — complaint fixed), but NO error of any kind appears at 10s or ~50s — no inline error, snackbar, or spinner. The missing-error-feedback leg is unchanged from 2266.
- Unknown email (nosuchuser-xyz123@example.com + WrongPass123): CHANGED vs 2266 — within 10s the form expands in place (Confirm password field + "New here? Confirm your password to create your account."), stable at ~50s; Back→Email re-entry shows the full sign-up mode (Confirm + Referral code (optional) + Create account button + "Already have an account? Sign in" footer). Sign-up was NOT completed; no account created. The e8e9420 merge list contains no auth commit, so the changed cause is unexplained by the batch — plausibly a server-side change.
- Control: test1@gmail.com + Test123 signs in within ~12s; chat history intact, badge 12.
- Operator incident (no verdict impact): a (950,1125) tap in the keyboard-down layout toggled the biometric consent off; diagnosed via uiautomator dump and re-checked. Rule: after any layout change, re-dump bounds before tapping.
Evidence: staging-dcd228d-retests_2026-11-02/2267-b12-wrongpw-noerror.png, 2267-b12-unknown-flip.png.

### SIMTASTE (sim-screen hung taste fetch) — PASS, with a stated caveat
- Completed Daniel×Sofia sim screen: the taste section renders in full — shared vibe chips (Atmospheric, Intimate, Introspective, Comedy, Drama, Indie, Indie Folk, Melancholic), "Both your tastes index with the 24 & under crowd", "You both listed" items, and the Qloo date-idea list. No "Comparing your tastes…" spinner anywhere; conversation, verdict, and actions all intact.
- Caveat: the fetch succeeded on this run, so the 60s timeout-to-absent-card degrade path itself was not black-box triggered; the bound (55s longTimeout + 5s) and the SizedBox.shrink rendering are code-verified. The brief's core bar — never sitting on "Comparing…" forever — holds on this specimen, the same one that stuck ~4 min in the sweep.
Evidence: staging-dcd228d-retests_2026-11-02/2267-simtaste-card.png.

### Voice-opener (dangling-message answer + honest pre-first-response state) — PASS
- Probe: "Voice probe two: say only the word mango." sent in main chat; voice opened ~1s later via the composer mic.
- Pre-first-response status read "Connecting…", never a fake "Listening…".
- The call's first voice turn observed live answered the dangling message — a new assistant turn "mango" rendered in chat and persisted server-side. After the first response the status legitimately read "Listening…". No silence at any point. Call ended cleanly with the stop button.
- ORDERING NOTE (disclosed, not hidden): the persisted history orders a standard greeting ("Hey Daniel, want to pick up where we left off…") and a "switched to my Kore voice with a British accent" notice BEFORE the "mango" turn, and a user fragment "Quick check, what is" (identical to a Nov 2-evening stray) sits between them. The live UI showed "mango" as the first voice turn at a guard-consistent time (~20s after open), before any greeting was visible — so the PASS rests on live production order, while the persisted order disagrees. The mid-call greeting + voice switch + recurring fragment are unexplained observations for whoever owns session logs; they do not change the observed opener behavior (answer, not silence, honest Connecting state).
Evidence: staging-dcd228d-retests_2026-11-02/2267-voice-connecting.png, 2267-voice-dangling-answer.png.

### TokenCap (voice after cap not silent) — BLOCKED, blocker named
- The cap fires only when the credit balance hits 0. Daniel held ~53 plan credits at the B12 sign-out (39 by the 2269 run after the evening's usage) — forcing the cap black-box would burn the seeded fixture's whole balance, which is destructive, not a test. No legitimate non-destructive cap route exists on this build.
- Partial coverage, not a substitute: the voice-opener result proves the downstream shape (a voice call opened after an unanswered turn speaks rather than opening silent), but the cap-state leg itself is untested. Dashboard records TokenCap as pending for this column.

### Guided tour — no interference
- Only the announcement card appeared on first 2267 launch ("Let Ayma show you around…"), dismissed via its own Skip tour button. The tour never auto-started and interfered with no retest.

### Incidents (both disclosed in the loop report)
1. F9 first attempt ANR (Nov 3, 00:02): system "Ayma isn't responding" dialog over a notification-permission sheet during an Explore search submit. ANR trace is a window-resize/focus race (FlutterView.onSizeChanged → viewport metrics), not a search-logic deadlock; the process died and relaunched signed out. The clean retry passed with no ANR and no permission dialog.
2. Build swap (00:02:09): the emulator was found running 2268, installed by an unidentified route (the watcher installs to the Pixel only; its log ends 23:59; no cron or script accounts for an emulator install at 00:02:09). All work 00:07–00:24 ran unknowingly on 2268 and counts for nothing. Scout caught it, downgrade-reinstalled verified 2267 with `install -r -d` at 00:29:03, re-verified, re-signed-in, and re-ran everything judged after that point on true 2267. P5 and F3 finished before the swap and are unaffected. Staging itself had advanced to 8b7e476/2268 during the run; 2268 was NOT judged.

## Addendum 7 — B12 retest after the staging permission fix (staging 85139e5, build 2269)
Run 01:07–01:19 PT Nov 3. Build verified: pubspec 1.30.0+2269, aapt versionCode 2269, on-device dumpsys 2269 (lastUpdateTime 01:07:15). Tip 85139e5 = merge of muse/b12-split-fix ("B12 split control-leg regression test (oracle fixed by staging SA Firebase Auth viewer grant)") on top of the fd334e0 tour rework (chromeless spotlight, advance ONLY on the real tap, no stray card). Per Astro's brief, the root cause of the 2266/2267 split failure was server-side: the staging backend's service account had no Firebase Auth permission, so the email-exists check failed on every call and the app could never decide between "wrong password" and "unknown email." The grant is staging-only, no client code change, no effect on the production hardening decision (founder checkpoint #4 stands).
Verdict: B12 PASS — all three legs pass. This closes the 2267 FAIL [S2, split]; the error-feedback gap is fixed.

### Leg 1 — known email + wrong password — PASS
- test1@gmail.com + WrongPass123 (12 chars screenshot-verified): form STAYS on sign-in (no flip), and a bottom error banner appears: "ERROR / That password is wrong — try again."
- Transience, measured: the banner is visible at 3s after resubmit and GONE by 15s. This explains the first submit's 10s/50s shots showing no error — the banner had already auto-dismissed (a UI-tree dump after the 50s shot found no error text anywhere). A user who looks away for ~10s misses it; whether that lifetime is acceptable is a product call, not a test failure — the brief's bar ("shows a wrong-password error") is met.
Evidence: staging-dcd228d-retests_2026-11-02/2269-b12-wrongpw-error.png.

### Leg 2 — unknown email — PASS
- nosuchuser-xyz123@example.com + WrongPass123: within 10s the form expands in place (Confirm password field + "New here? Confirm your password to create your account."); keyboard-down view confirms the full sign-up mode (Confirm + Referral code (optional) + Create account + "Already have an account? Sign in" footer). Sign-up was NOT completed; no account created.
Evidence: staging-dcd228d-retests_2026-11-02/2269-b12-unknown-flip.png.

### Leg 3 — control, correct password — PASS
- test1@gmail.com + Test123 (7 chars, screenshot-verified): signed in within ~12s; Daniel's main chat restored with full history intact (including the voice-probe turns), badge 12.

### Operator notes (no verdict impact)
- The password row's eye toggle sits at x≈880–1006 in the keyboard-up layout: a far-right tap (950,1470) hit the eye icon instead of the field, unmasking the password and swallowing the following backspaces/typing. Recovered by tapping the field's text area (x≈500) and verifying the end cursor before clearing. Rule: never tap x>880 in a password row; tap the text area.
- One tool call was interrupted mid-run during the control leg; Scout re-checked state by screenshot before continuing (no state damage: email intact, password still WrongPass123 visible).
- After the 2269 reinstall the app cold-started and an early tap sequence landed in the Google app search UI; recovered by Back-ing to the launcher and relaunching via monkey. Lesson: after an install, re-establish the foreground app before tapping nav coordinates.
