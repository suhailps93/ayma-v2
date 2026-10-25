# Google Play reviewer access (Play Console, "App access")

Credentials are NOT in this repo. They live in Google Secret Manager as
`PLAY_REVIEWER_CREDENTIALS` (project `ayma-ai`, JSON with `email` and `password`).
Paste them into Play Console > App content > App access.

## Text to paste into "App access"

Ayma requires sign-in. Use the pre-created test account (email and password
supplied in the credentials fields above).

1. Open the app. On the sign-in screen choose the email option and sign in with
   the supplied email and password (do not use "Create account"). Google and
   phone sign-in also exist but are not needed.
2. The account is already onboarded, so the app opens directly on the main
   screen. No payment, subscription, or onboarding is required.
3. Features to review:
   - Talk to Ayma: tap the call/voice button to start a live voice conversation
     with Ayma, our AI matchmaker. Allow the microphone permission when asked.
     A text chat with Ayma is also available.
   - Explore: browse other members' profiles from the bottom navigation.
   - Matches and Messages: view matches and message threads.
   - Profile: view and edit the profile, photos, and Ayma settings.
   - Settings: notifications, voice, accent colour, usage and credits, privacy
     policy, terms, feedback.
   The face-matching consent every member gives is already recorded for
   this account, so no consent screen appears.
4. The test account has starter credits for AI features. Members must be 18+.
   The test account's profile is hidden from other members.

## Biometric consent seed (internal, not for Play Console)

The face-matching consent is mandatory for every account, and the API refuses
feature calls without it. Record it server-side for the reviewer account once
(and again after any `CONSENT_VERSION` bump in `biometric_consent.py`), from
`functions/bootstrap/` with `GOOGLE_APPLICATION_CREDENTIALS` set:

    python scripts/seed_biometric_consent.py <reviewer email or uid> --region US

It uses the same validation as `POST /biometric-consent` and tags the record
`source: admin_seed`. Signing in and tapping "I agree" works too.
