// The face-matching (biometric) consent every Ayma member gives before using
// the app. Kept in step with the "Biometric information" sections of
// docs/PRIVACY.md / docs/TERMS.md (and privacy_text.dart / terms_text.dart).
// The version must match `CONSENT_VERSION` in
// functions/bootstrap/biometric_consent.py — the server refuses any other.
// Wording to be reviewed by an attorney before store release.

// Bumped to `2026-10-25.2` with the Terms/Privacy update (advertising use,
// encryption): existing accounts see the one-time consent screen again, which
// also asks them to accept the updated Terms.
const String kBiometricConsentVersion = '2026-10-25.2';

const String kBiometricConsentTitle = 'Face matching';

/// The one-sentence face-recognition consent on the sign-in page.
const String kBiometricConsentSignInLine =
    'Ayma analyses your photos with face recognition, including matching them '
    'against photos on the public web, so it can match you and verify '
    'profiles.';

const String kBiometricConsentText = r'''
Ayma uses face recognition on your photos. Before we go any further, here is exactly what that means.

**What we do**

- We analyse the photos you add (your profile photos, your verification selfie, and photos you share with Ayma) with face recognition.
- From those photos we create face data: a set of numbers (an "embedding") that describes your face. It is not a photo and it's never shown to anyone.
- We compare your face data with photos we find of you on the public web, so your profile and your "web search about me" only use photos that really are you.
- Other Ayma members can run a deep dive on you from Explore. When they do, Ayma uses your face data the same way, to make sure the photos it shows them are actually you.

**What we keep**

- Your face data, plus the links to web photos that matched you and how closely they matched. We never keep copies of web photos.
- We never sell your face data, and we never use it for advertising.

**How long we keep it**

- For as long as your account exists. When your account is deleted, your face data goes with it, on the schedule in our Privacy Policy.

**Changing your mind**

- You can withdraw this consent any time in Settings. Face matching is part of how Ayma works, so withdrawing deletes your face data right away and then deletes your account. You can also just sign out.

Ayma can't be used without this consent.
''';

const String kBiometricConsentCheckbox =
    'I agree that Ayma can analyse my photos with face recognition, create '
    'face data from them, and match it against photos on the public web, '
    "including for other members' deep dives on me.";
