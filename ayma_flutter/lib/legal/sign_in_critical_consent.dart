import 'biometric_consent_text.dart';

/// The critical consent items a user must be aware of before signing in —
/// what the sign-in greeting voice reads out / shows when the user asks "is
/// there anything critical I should be aware of?" (§3.3).
///
/// This is a legal/consent surface: every line is kept faithful to the
/// on-screen clickwrap copy and the Biometric Information consent
/// ([kBiometricConsentSignInLine]) — it must not invent or soften a term. The
/// four points mirror, in order, the two sign-in checkboxes: 18+, the Terms
/// (which include use of data for advertising), face recognition (incl.
/// public-web matching), and the Privacy Policy.
const List<String> kSignInCriticalConsentPoints = [
  'You must be 18 or older to use Ayma.',
  'By agreeing to the Terms, you agree to the use of your data for '
      'advertising.',
  kBiometricConsentSignInLine,
  'The Privacy Policy governs how your data is used.',
];

/// The four [kSignInCriticalConsentPoints] as one plain-text summary — the
/// faithful wording the voice greeting conveys and the test asserts on.
final String kSignInCriticalConsentSummary =
    kSignInCriticalConsentPoints.join(' ');
