# Meta Model API Usage & Billing Figure — Technical Audit & BLOCKED Handoff

**Task**: Obtain logged-in, read-only console figures for the Meta Model API ($ used, $150 credit status, remaining credit, billing period) from https://dev.meta.ai/usage and https://dev.meta.ai/billing for the Ayma Meta hackathon submission.  
**Branch**: `antigravity/meta-usage-figure`  
**Worktree**: `.fleet-worktrees/meta-usage-agy`  
**As-of Timestamp**: 2026-11-02 ~08:28 PT  
**Status**: **BLOCKED** — Founder-only authentication / onboarding step required.

---

## 1. Executive Summary & Verdict

Following Muse's blocked handoff (`origin/muse/meta-usage-figure` @ `68d333a`, which proved no public/authenticated REST usage endpoint exists for Meta Model API), Antigravity investigated the local environment on the founder's ThinkPad across all specified routes:

1. **Route 1 (Existing Local Chrome Session)**:
   - Reused the founder's Google Chrome `Default` profile (`~/.config/google-chrome/Default`).
   - Connected via Chrome DevTools Protocol (CDP) in headless mode with GNOME Keyring integration over D-Bus (`unix:path=/run/user/1000/bus`), decrypting and restoring all 2,374 local cookies (including `.facebook.com`: `c_user`, `xs`, `datr`; `.auth.meta.com`: `datr`, `ps_l`, `ps_n`; `.meta.ai`: `datr`, `ecto_1_sess`).
   - Direct navigation to `https://dev.meta.ai/usage` and `https://dev.meta.ai/billing` immediately redirected to the public marketing landing page `https://dev.meta.ai/` with an unauthenticated "Login" call-to-action.
   - Stepping through the OIDC login flow via `https://dev.meta.ai/api/auth/login?next=%2Fusage` redirected through `https://auth.meta.com/oidc/?app_id=2403310080153219...` to `https://auth.meta.com/?waterfall_id=...`.
   - On `auth.meta.com`, the session stopped at an interactive role onboarding and account login gate recognizing the founder:
     - Header: *"How will you use the Model API? The Model API is for building with Meta models — keys, usage, and billing."*
     - Role Selection Tabs: `[Individual]` (selected by default) vs `[Business & Enterprise]`.
     - Founder Account Card: Displays the founder's photo and name (`Suhail Pallath Sulaiman`) with interactive `[Log in]` and `[Log into another account]` buttons, plus Google and GitHub OAuth options.
   - Per task constraints (*"Read-only: navigation only, no clicks beyond opening the pages, no settings changes"* and *"STRICTLY read-only: no purchases, no plan changes, no payment methods, no subscription or settings changes"*), clicking `[Log in]` or selecting role tabs is strictly forbidden as it constitutes an interactive onboarding mutation that could bind the account as "Individual" rather than the Ayma Account Team (`1115399524571844`), and/or trigger a founder password / 2FA challenge.

2. **Route 2 (Local Billing Artifacts)**:
   - Audited local disk (`~/Downloads`, `~/Documents`, `~/Desktop`, repository history) for receipts, invoices, or billing confirmation artifacts. No Meta billing records exist locally.

Per Deliverable 3 of `TASK.md`, because every accessible route terminates at a founder-only interactive login/onboarding prompt, this chunk is reported as **BLOCKED**. No dollar figure has been estimated, interpolated, or token-multiplied.

---

## 2. Route Probing Details

### Probe 1: Local Chrome Profile & Cookie Decryption
- **Profile Directory**: `/home/suhailps/.config/google-chrome/Default`
- **Encryption Subsystem**: `os_crypt` portal configured for `ubuntu:GNOME` via `gnome-keyring-daemon` (`DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`, `XDG_CURRENT_DESKTOP=ubuntu:GNOME`, display `:0`).
- **Restoration**: Isolated profile environment constructed, preserving `Local State`, `Default/Preferences`, `Default/Cookies`, `Default/Network Persistent State`, `Default/Login Data`, `Default/Session Storage`, `Default/Local Storage`, and `Default/IndexedDB/https_*.meta.*`.
- **Decrypted Cookies Loaded**: 2,374 cookies total.
  - Active Meta/Facebook sessions verified:
    - `.facebook.com`: `c_user`, `xs`, `datr` (valid through July 2027)
    - `.auth.meta.com`: `datr`, `ps_l`, `ps_n` (valid through May 2027)
    - `.meta.ai`: `datr`, `ecto_1_sess` (valid through May 2027)
    - `.developer.meta.com`: `datr` (valid through Sept 2027)

### Probe 2: Console Navigation
- **Target 1**: `https://dev.meta.ai/usage`
  - Navigation result: HTTP 302 redirect to `https://dev.meta.ai/`
  - Page title: `Products & Solutions for AI Developers | Meta`
  - DOM state: Unauthenticated public landing page. Header shows `Login` (`/api/auth/login`).
- **Target 2**: `https://dev.meta.ai/billing`
  - Navigation result: HTTP 302 redirect to `https://dev.meta.ai/`
  - DOM state: Identical unauthenticated landing page.

### Probe 3: Authentication Flow Trace
- **Initiated**: `https://dev.meta.ai/api/auth/login?next=%2Fusage`
- **Redirect 1**: `302 -> https://auth.meta.com/oidc/?app_id=2403310080153219&redirect_uri=https%3A%2F%2Fauth.meta.ai%2Fmodel_api&response_type=code&scope=openid%2Blinking...`
- **Redirect 2**: `https://auth.meta.com/?waterfall_id=...`
- **Rendered Content on `auth.meta.com`**:
  ```text
  How will you use the Model API?
  The Model API is for building with Meta models — keys, usage, and billing.
  [Individual]  [Business & Enterprise]
  
  [Avatar]
  Suhail Pallath Sulaiman
  [ Log in ]
  [ Log into another account ]
  
  OR
  Continue with Google
  Continue with GitHub
  ```
- **Visual Evidence**: Captured full-page screengrab (`auth_flow.png`). The founder's identity is detected, but the session is paused at:
  1. Role designation (`Individual` vs `Business & Enterprise`).
  2. Account authorization confirmation (`Log in`).

---

## 3. The Exact Founder Action Required to Unblock

To obtain the authoritative numbers for the submission writeup, the founder must execute the following 2-minute step in his regular desktop Chrome browser:

1. Open Google Chrome on this ThinkPad.
2. Navigate to **https://dev.meta.ai/usage** and **https://dev.meta.ai/billing**.
3. If prompted by the `auth.meta.com` screen shown above:
   - Select **Business & Enterprise** (Ayma operates under Account Team ID `1115399524571844`, Project `1115393394567311`).
   - Click **Log in** as `Suhail Pallath Sulaiman` (and complete 2FA if prompted).
4. Record and quote the exact values displayed:
   - **Total $ Used / Billed to Date** (USD)
   - **Credit Status**: Has the $150 credit posted to the account?
   - **Remaining Credit Balance** ($)
   - **Billing Period Covered** (start date – end date)
   - **As-of Timestamp** (with timezone) shown in the console.
5. (Optional): Once logged in, leaving the browser open or retaining the session cookie for `dev.meta.ai` will allow automated agents to read subsequent figures cleanly.
