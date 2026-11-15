# Scout Device Verification Steps — Build 2447 (NOTE 223)

## Leg 1: Feedback Pop-Up Fixes (No Reappear & Thanks Auto-Dismiss)

Both fixes are merged into staging tip `07c1fda4` (Batch 2447):
- `fleet/feedback-unify-no-reappear` (batch 2383, commit `40b0fcf1` / `66e1ca1a`)
- `fleet/feedback-thanks-dismiss` (founder fast-track, commit `73aa8e2e` / `4a03a491`)

### Scenario 1A: Feedback Card Never Reappears as Sendable Draft on Relaunch/Rebuild

1. Open Ayma and sign in to Daniel's account on build 2447.
2. Navigate to the **Ayma Chat** tab (Main tab).
3. Type or voice a bug or feature feedback request, e.g.:
   `"I want to report a bug: the photo upload is slow."`
   or
   `"I'd like to suggest a feature: dark mode calendar view."`
4. **Expected Result:** Ayma responds and displays an inline `FeedbackDraftCard` with the draft kind, title, body, and action buttons (`Send`, `Edit`, `Not now`).
5. Review the card and tap **Send**.
6. **Expected Result:**
   - A success toast appears: `Thanks — sent to the team.`
   - The card switches to its confirmation sent view: green checkmark icon with text `Thanks — sent to the team.`
7. Rebuild / relaunch the chat:
   - Navigate away from the chat (e.g. switch to Explore or Profile tab) and return to Chat, **OR**
   - Scroll up and down past the message to trigger ListView recycling, **OR**
   - Force close and relaunch the app back into the chat.
8. **Expected Result:**
   - The feedback card does **NOT** return as a fresh, sendable draft card with `Send` / `Not now` buttons.
   - The draft card remains resolved (`sent-shown` renders collapsed `SizedBox.shrink()`). Feedback cannot be submitted twice.

### Scenario 1B: Transient Thanks Card Auto-Dismisses After ~3 Seconds

1. Open the **Ayma Chat** tab.
2. Ask Ayma to capture feedback or report an issue again:
   `"Report a bug: profile picture cropped oddly."`
3. Ayma presents the inline feedback card.
4. Tap **Send**.
5. Observe the card immediately after tapping Send:
   - **0s - 3s:** The card transitions to the inline sent state showing the green checkmark and `Thanks — sent to the team.` alongside the success toast.
   - **~3s mark:** The thanks confirmation card automatically expires and collapses/dismisses itself completely from the thread.
6. Observe the transcript after 3 seconds:
   - **Expected Result:** The thanks card is gone from the thread entirely.
   - Scrolling away and back or reopening the chat never resurrects the card or leaves a permanent lingering confirmation widget.

---

## Leg 2: NOTE 216 Defect (a) — Location Log System Popup on First Denial (Fresh State)

Merged fix: `fleet/privacy-toggle-permission-popup` (`d6260987`) and `17f7daf2`.
Tested by: `test/privacy_location_test.dart` (20 passed).

### Fixture Caveat (Crucial)
The standard automated Daniel fixture profile has previously had location permissions permanently denied (`USER_FIXED` / `LocationPermission.deniedForever`). On Android, once a permission is permanently denied (`deniedForever`), the OS will not show the system runtime permission dialog again and apps must route to App Info / Settings.
**Therefore, testing the first-denial system popup half requires a fresh never-asked state.**

### Scenario 2A: Fresh-State System Permission Popup on First Toggle

1. Ensure the app has fresh/clean permissions:
   - Run `adb shell pm clear com.ayma.app` (or wipe app data via Android Settings -> Apps -> Ayma -> Storage & Cache -> Clear Storage), **OR** perform a clean install of build 2447.
2. Launch Ayma and complete sign-in (or sign in to Daniel).
3. Tap the **Profile** tab (far right).
4. Tap **Privacy & Data**.
5. Ensure the master **Location** toggle is ON (this reveals the sub-toggles: Date moments, Location log).
6. Locate the **Location log** toggle (which starts OFF in a fresh state).
7. Tap the **Location log** toggle to turn it ON.
8. **Expected Result (System Popup Appears):**
   - The Android system location permission dialog **MUST** appear on screen asking for location permission (e.g. *"While using the app"* / *"Only this time"* / *"Don't allow"*).
   - The app does **NOT** silently fail.
   - The app does **NOT** immediately skip to system Settings without prompting.
9. Tap **"Don't allow"** (first denial):
   - **Expected Result:**
     - The system dialog dismisses.
     - The **Location log** switch remains **OFF**.
     - An informative feedback toast appears: `"Location log needs location permission. Turn it on again when you're ready to allow it."`
     - The app does **NOT** get stuck in a dead-end, nor does it abruptly jump to Settings on this first denial.
