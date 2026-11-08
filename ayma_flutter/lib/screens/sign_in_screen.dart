import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../legal/biometric_consent_text.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/biometric_consent.dart';
import '../services/legal_links.dart';
import '../services/sign_in_voice_intent.dart';
import '../services/transcript_store.dart';
import '../services/voice_session_controller.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/phone_number_field.dart';
import 'biometric_info_screen.dart';
import 'sign_in_critical_consent_dialog.dart';
import 'splash_screen.dart';

/// The sign-in gate (§3.3). The app requires a real credential up front — no
/// anonymous browsing — so this is the first screen an unauthenticated user
/// sees. On success it routes to [SplashScreen], which bootstraps and sends the
/// user on to the voice intro / preboarding / main app.
///
/// Clickwrap: two separate, required checkboxes (unticked by default) — the
/// Terms + Privacy Policy, and the face-recognition (biometric) consent —
/// and every sign-in button stays disabled until both are ticked. The
/// biometric consent is kept on the device ([PendingBiometricConsent]) and
/// recorded server-side by the splash screen right after sign-in.
class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    this.auth,
    this.voiceController,
    this.apiClient,
    this.startInCreateAccountMode = false,
  });

  static const path = '/signin';

  final AuthService? auth;

  /// Injectable for tests / the layout matrix: open directly on the email
  /// stage in create-account mode (confirm-password + referral fields shown),
  /// so that taller variant's layout is covered without driving taps.
  final bool startInCreateAccountMode;

  /// Injectable for tests; used only to redeem a referral code right after a
  /// new account is created.
  final ApiClient? apiClient;

  /// Injectable for tests; the greeting orb runs a pre-sign-in voice session.
  final VoiceSessionController? voiceController;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

enum _Stage { pick, email, phone }

class _SignInScreenState extends State<SignInScreen> {
  late final AuthService _auth = widget.auth ?? AuthService();

  late final TranscriptStore _transcript = TranscriptStore();
  late final VoiceSessionController _voice =
      widget.voiceController ??
      VoiceSessionController(transcriptStore: _transcript, welcome: true);

  _Stage _stage = _Stage.pick;
  bool _busy = false;

  /// True only while [_forgotPassword]'s reset-email send is the in-flight
  /// op — label state only, so the busy line below names the real work.
  bool _sendingReset = false;

  /// The busy line names the actual in-flight op, derived from existing
  /// state: OAuth/email sign-ins, account creation, phone verification
  /// (code send and code confirm are both number verification), or the
  /// password-reset send.
  List<String> get _busyLines {
    if (_sendingReset) return AymaLoaderLines.resetEmail;
    if (_stage == _Stage.phone) return AymaLoaderLines.phoneVerify;
    if (_stage == _Stage.email && _createMode) return AymaLoaderLines.signUp;
    return AymaLoaderLines.signIn;
  }

  /// The two clickwrap boxes; both are required before any sign-in.
  bool _termsAccepted = false;
  bool _biometricAccepted = false;
  bool get _consentsGiven => _termsAccepted && _biometricAccepted;

  void _setBiometric(bool value) {
    setState(() => _biometricAccepted = value);
    if (value) {
      PendingBiometricConsent.save(kBiometricConsentVersion);
    } else {
      PendingBiometricConsent.clear();
    }
  }

  /// Email flow mode: false = sign in to an existing account, true = create
  /// a new one. The two used to be one ambiguous "Continue" that silently
  /// created an account on an unknown email; now the user picks explicitly.
  bool _createMode = false;

  /// Set after a password-reset email goes out, so the sign-in form can show
  /// its "check your email" confirmation inline.
  String? _resetSentTo;

  /// A short inline nudge shown in create mode right after a failed sign-in
  /// auto-switched the user here ("New here? Confirm your password…"). Null
  /// the rest of the time — a plain, deliberate switch shows no nudge.
  String? _createHint;

  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();

  /// Per-field show/hide toggles — independent of each other, both start
  /// obscured.
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  final _confirmFocus = FocusNode();
  final _referral = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _phoneFieldKey = GlobalKey<PhoneNumberFieldState>();
  String? _verificationId;

  bool get _appleOffered =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  /// The last finalized user voice turn already acted on, so a repeated
  /// transcript notification for the same turn never re-navigates or
  /// re-opens the critical-consent dialog.
  TranscriptTurn? _lastHandledVoiceTurn;

  /// Guards against opening a second critical-consent dialog while one is up.
  bool _criticalConsentOpen = false;

  @override
  void initState() {
    super.initState();
    if (widget.startInCreateAccountMode) {
      _stage = _Stage.email;
      _createMode = true;
    }
    _voice.addListener(_onVoice);
    // The greeting (§3.3) can act on two spoken legal/consent intents — "open
    // terms / privacy / biometric" and "is there anything critical I should
    // know?". The pre-sign-in welcome room has no uid, so the backend
    // AppCommandService navigation path is dead; instead the app watches the
    // user's own finalized voice turns in the shared transcript and handles
    // these locally with the same navigation the clickwrap links use.
    _voice.transcript.addListener(_onTranscript);
    // Ayma greets while they choose how to sign in. Best-effort — a mic denial
    // or offline just leaves the orb quiet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.voiceController == null) _voice.start();
    });
  }

  void _onVoice() {
    if (mounted) setState(() {});
  }

  /// A transcript segment landed. Act once on the latest finalized *user*
  /// voice turn if it carries a sign-in legal/consent intent.
  void _onTranscript() {
    if (!mounted) return;
    final turns = _voice.transcript.turns;
    if (turns.isEmpty) return;
    final last = turns.last;
    if (last.role != TurnRole.user ||
        last.source != TurnSource.voice ||
        !last.isFinal) {
      return;
    }
    if (identical(last, _lastHandledVoiceTurn)) return;
    _lastHandledVoiceTurn = last;
    switch (parseSignInVoiceIntent(last.text)) {
      case SignInVoiceIntent.openTerms:
        LegalLinks.openTerms(context);
      case SignInVoiceIntent.openPrivacy:
        LegalLinks.openPrivacy(context);
      case SignInVoiceIntent.openBiometric:
        context.push(BiometricInfoScreen.path);
      case SignInVoiceIntent.critical:
        if (_criticalConsentOpen) return;
        _criticalConsentOpen = true;
        showSignInCriticalConsent(context)
            .whenComplete(() => _criticalConsentOpen = false);
      case SignInVoiceIntent.none:
        break;
    }
  }

  Future<void> _stopVoice() async {
    _voice.removeListener(_onVoice);
    _voice.transcript.removeListener(_onTranscript);
    if (widget.voiceController == null && _voice.isActive) {
      await _voice.stop();
    }
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoice);
    _voice.transcript.removeListener(_onTranscript);
    if (widget.voiceController == null) {
      _voice.stop();
      _voice.dispose();
    }
    _transcript.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _confirmFocus.dispose();
    _referral.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  void _snack(String m, {AymaToastKind kind = AymaToastKind.info}) {
    if (!mounted) return;
    AymaToast.show(context, m, kind: kind);
  }

  /// [onAuthError], when given, gets first look at a [FirebaseAuthException]:
  /// if it returns true it has handled the error (e.g. steered the user into
  /// another mode) and the default error toast is suppressed. Only the email
  /// flows pass it; Google/Apple/phone keep the plain toast. It is async
  /// because the sign-in handler may consult the server existence oracle.
  Future<void> _run(
    Future<UserCredential> Function() action, {
    Future<bool> Function(FirebaseAuthException e)? onAuthError,
  }) async {
    if (_busy || !_consentsGiven) return;
    setState(() => _busy = true);
    try {
      await action();
      await _stopVoice();
      if (!mounted) return;
      context.go(SplashScreen.path);
    } on FirebaseAuthException catch (e) {
      if (onAuthError == null || !await onAuthError(e)) {
        _snack(_friendly(e), kind: AymaToastKind.error);
      }
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled) {
        _snack('Google sign-in failed (${e.code.name}).',
            kind: AymaToastKind.error);
      }
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code != AuthorizationErrorCode.canceled) {
        _snack('Apple sign-in isn’t set up yet.', kind: AymaToastKind.warning);
      }
    } catch (e) {
      _snack('Sign-in failed. Try again.', kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(FirebaseAuthException e) {
    switch (e.code) {
      case 'wrong-password':
      case 'invalid-credential':
        // Newer Firebase reports both a wrong password and an unknown email
        // as `invalid-credential` (email-enumeration protection), so steer
        // toward both fixes.
        return 'That email and password don’t match. New here? '
            'Tap “Sign up” below.';
      case 'user-not-found':
        return 'No account with that email yet — tap “Sign up” to create one.';
      case 'invalid-email':
        return 'That doesn’t look like an email address.';
      case 'weak-password':
        return 'Pick a password of at least 6 characters.';
      case 'email-already-in-use':
        return 'That email already has an account — tap “Sign in” instead.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a minute and try again.';
      case 'operation-not-allowed':
        return 'That sign-in method isn’t enabled yet.';
      default:
        return 'Sign-in failed. Check your details and try again.';
    }
  }

  Future<void> _submitEmail() async {
    final email = _email.text.trim();
    if (email.isEmpty || _password.text.length < 6) {
      _snack('Enter an email and a password of at least 6 characters.',
          kind: AymaToastKind.warning);
      return;
    }
    if (_createMode && _confirmPassword.text != _password.text) {
      _snack('Those passwords don’t match.', kind: AymaToastKind.warning);
      return;
    }
    await _run(
      () => _createMode
          ? _createAccountAndRedeemReferral(email)
          : _auth.signInWithEmailPassword(email, _password.text),
      onAuthError: _createMode ? _onCreateError : _onSignInError,
    );
  }

  /// A failed *sign-in*. The explicit codes decide directly: `user-not-found`
  /// means an unknown email (offer sign-up), `wrong-password` means an
  /// existing account with a mistyped password (stay, say so). But under
  /// email-enumeration protection newer Firebase reports BOTH as
  /// `invalid-credential` — and the client cannot break that tie itself
  /// (`fetchSignInMethodsForEmail` is blanked) — so for that code we ask the
  /// server existence oracle (`POST /auth/email-exists`, Admin SDK) and only
  /// flip to sign-up when the email genuinely has no account. A wrong
  /// password on an existing account therefore never flips modes (founder
  /// bug: the flip read as "this login doesn't exist"). If the oracle itself
  /// fails we stay put with the generic error — never flip on a guess.
  Future<bool> _onSignInError(FirebaseAuthException e) async {
    if (e.code == 'user-not-found') {
      _flipToCreate();
      return true;
    }
    if (e.code == 'wrong-password') {
      _snack('That password is wrong — try again.',
          kind: AymaToastKind.error);
      return true;
    }
    if (e.code != 'invalid-credential') return false;
    final email = _email.text.trim();
    bool exists;
    try {
      exists =
          await (widget.apiClient ?? ApiClient()).emailExists(email);
    } catch (_) {
      if (!mounted) return true;
      _snack(_friendly(e), kind: AymaToastKind.error);
      return true;
    }
    if (!mounted) return true;
    if (exists) {
      _snack('That password is wrong — try again.',
          kind: AymaToastKind.error);
      return true;
    }
    _flipToCreate();
    return true;
  }

  /// Switch to create mode, keeping the typed email + password, revealing and
  /// focusing the confirm field, and showing the friendly nudge.
  void _flipToCreate() {
    setState(() {
      _createMode = true;
      _resetSentTo = null;
      _createHint = 'New here? Confirm your password to create your account.';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _confirmFocus.requestFocus();
    });
  }

  /// A failed *create*: an `email-already-in-use` means the account exists, so
  /// switch back to sign-in so they can correct the password rather than stay
  /// stuck on the sign-up form.
  Future<bool> _onCreateError(FirebaseAuthException e) async {
    if (e.code != 'email-already-in-use') return false;
    setState(() {
      _createMode = false;
      _createHint = null;
    });
    _snack('You already have an account — check your password.',
        kind: AymaToastKind.warning);
    return true;
  }

  /// Creates the account, then best-effort redeems any referral code typed in
  /// the optional sign-up field — the server records durable attribution
  /// (`referred_by`). A bad/expired code must never fail the sign-up, so any
  /// redeem error is swallowed.
  Future<UserCredential> _createAccountAndRedeemReferral(String email) async {
    final cred =
        await _auth.createAccountWithEmailPassword(email, _password.text);
    final code = _referral.text.trim();
    if (code.isNotEmpty) {
      try {
        await (widget.apiClient ?? ApiClient()).redeemReferral(code);
      } catch (_) {/* attribution is best-effort */}
    }
    return cred;
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      _snack('Enter your email above first, then tap “Forgot password?”.',
          kind: AymaToastKind.warning);
      return;
    }
    setState(() {
      _busy = true;
      _sendingReset = true;
    });
    try {
      await _auth.sendPasswordResetEmail(email);
      if (mounted) setState(() => _resetSentTo = email);
    } on FirebaseAuthException catch (e) {
      _snack(switch (e.code) {
        'user-not-found' =>
          'No account with that email — tap “Sign up” to create one.',
        'invalid-email' => 'That doesn’t look like an email address.',
        'too-many-requests' =>
          'Too many attempts. Wait a minute and try again.',
        _ => 'Couldn’t send the reset email. Try again in a moment.',
      }, kind: AymaToastKind.error);
    } catch (_) {
      _snack('Couldn’t send the reset email. Try again in a moment.',
          kind: AymaToastKind.error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _sendingReset = false;
        });
      }
    }
  }

  Future<void> _sendCode() async {
    if (!_consentsGiven) return;
    final field = _phoneFieldKey.currentState;
    if (field == null || !field.isPlausible) {
      _snack('Enter your phone number.', kind: AymaToastKind.warning);
      return;
    }
    final phone = field.e164;
    setState(() => _busy = true);
    try {
      await _auth.startPhoneSignIn(
        phone,
        codeSent: (id) {
          if (!mounted) return;
          setState(() {
            _verificationId = id;
            _busy = false;
          });
          _snack('Code sent.', kind: AymaToastKind.success);
        },
        verificationFailed: (e) {
          if (!mounted) return;
          setState(() => _busy = false);
          _snack(_friendly(e), kind: AymaToastKind.error);
        },
        autoSignedIn: (_) async {
          await _stopVoice();
          if (mounted) context.go(SplashScreen.path);
        },
      );
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _snack(_friendly(e), kind: AymaToastKind.error);
      }
    }
  }

  Future<void> _confirmCode() async {
    final id = _verificationId;
    if (id == null || _code.text.trim().isEmpty) return;
    await _run(() => _auth.confirmPhoneCode(id, _code.text));
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _busy,
          child: Center(
            child: SingleChildScrollView(
              // iOS has no keyboard-dismiss key — dragging the form away is
              // the native escape hatch.
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 40, 20, 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: GestureDetector(
                        onTap: () =>
                            _voice.isActive ? _voice.stop() : _voice.start(),
                        // This is the app's one standalone "brand mark" orb
                        // moment (vs. the many small inline loading spinners
                        // elsewhere), so it gets its own soft backdrop glow —
                        // the orb's shared painter auto-suppresses glow below
                        // the medium size breakpoint, which is right for an
                        // inline spinner but left this 76px hero sitting with
                        // a hard edge directly on the dark theme's near-black
                        // background, reading as "the logo has a black
                        // background". A wide, very soft radial glow behind
                        // it (invisible in light theme's already-cream
                        // background) closes that gap without touching the
                        // shared tier rule other call sites rely on.
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                ac.accent.withValues(alpha: 0.16),
                                ac.accent.withValues(alpha: 0),
                              ],
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: AymaOrb(
                              size: 76,
                              active: _voice.isActive,
                              amplitudeListenable: _voice.agentSpeaking
                                  ? _voice.aymaLevel
                                  : _voice.micLevel,
                              state: _voice.agentSpeaking
                                  ? AymaOrbState.speaking
                                  : (_voice.phase ==
                                                VoiceSessionPhase.connecting ||
                                            _voice.phase ==
                                                VoiceSessionPhase.waking
                                        ? AymaOrbState.thinking
                                        : (_voice.isActive
                                              ? AymaOrbState.listening
                                              : AymaOrbState.idle)),
                              // "Connected" glow only once Ayma is genuinely
                              // listening — not during connecting/waking — so
                              // the greeting orb reads as live only when it
                              // truly is (same source of truth as the call
                              // notification; the state switch above already
                              // holds `thinking` until then).
                              voiceLive: _voice.isListening,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Small hint under the orb while Ayma's greeting is live,
                    // so a user who doesn't want to be spoken to can silence
                    // her. Tapping it (or the orb) stops the voice session.
                    if (_voice.isActive) ...[
                      const SizedBox(height: 8),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _voice.stop(),
                        child: Text(
                          'Tap to mute',
                          textAlign: TextAlign.center,
                          style: AymaType.sans(size: 12, color: ac.fgMute),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Text(
                      'AYMA',
                      textAlign: TextAlign.center,
                      style: AymaType.mono(
                        size: 12,
                        color: ac.fgMute,
                      ).copyWith(letterSpacing: 6),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your AI matchmaker',
                      textAlign: TextAlign.center,
                      style: AymaType.serif(size: 26, color: ac.fg),
                    ),
                    // 6 here + the consent rows' own 18dp overlay room
                    // (see _ConsentBoxesState._kOverlayTopRoom) = the 24dp
                    // this gap has always rendered as.
                    const SizedBox(height: 6),
                    _ConsentBoxes(
                      termsAccepted: _termsAccepted,
                      biometricAccepted: _biometricAccepted,
                      onTerms: (v) => setState(() => _termsAccepted = v),
                      onBiometric: _setBiometric,
                    ),
                    const SizedBox(height: 16),
                    if (_stage == _Stage.pick) ..._pick(ac),
                    if (_stage == _Stage.email) ..._emailForm(ac),
                    if (_stage == _Stage.phone) ..._phoneForm(ac),
                    const SizedBox(height: 24),
                    if (_busy)
                      Center(
                        child: AymaWingLoader(size: 56, lines: _busyLines),
                      )
                    else if (_stage != _Stage.pick)
                      TextButton(
                        onPressed: () => setState(() {
                          _stage = _Stage.pick;
                          _verificationId = null;
                          _resetSentTo = null;
                        }),
                        child: const Text('Back'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _pick(AymaTokens ac) => [
    // Apple leads as one prominent, solid full-width button — iOS/macOS
    // only (`_appleOffered`). Google/email/phone follow as a single row of
    // equal compact buttons, never stacked full-width like Apple's.
    if (_appleOffered) ...[
      _AppleBtn(
        onTap: _consentsGiven ? () => _run(_auth.signInWithApple) : null,
      ),
      const SizedBox(height: 12),
    ],
    Row(
      children: [
        Expanded(
          child: _CompactBtn(
            icon: Icons.g_mobiledata,
            label: 'Google',
            onTap: _consentsGiven ? () => _run(_auth.signInWithGoogle) : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _CompactBtn(
            icon: Icons.mail_outline,
            label: 'Email',
            onTap: _consentsGiven
                ? () => setState(() => _stage = _Stage.email)
                : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _CompactBtn(
            icon: Icons.phone_outlined,
            label: 'Phone',
            onTap: _consentsGiven
                ? () => setState(() => _stage = _Stage.phone)
                : null,
          ),
        ),
      ],
    ),
  ];

  List<Widget> _emailForm(AymaTokens ac) => [
    TextField(
      controller: _email,
      keyboardType: TextInputType.emailAddress,
      autocorrect: false,
      decoration: const InputDecoration(labelText: 'Email'),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _password,
      obscureText: _obscurePassword,
      onSubmitted: (_) => _submitEmail(),
      decoration: InputDecoration(
        labelText: 'Password',
        suffixIcon: IconButton(
          tooltip: _obscurePassword ? 'Show password' : 'Hide password',
          icon: Icon(
              _obscurePassword ? Icons.visibility_off : Icons.visibility),
          onPressed: () =>
              setState(() => _obscurePassword = !_obscurePassword),
        ),
      ),
    ),
    if (_createMode) ...[
      const SizedBox(height: 12),
      TextField(
        controller: _confirmPassword,
        focusNode: _confirmFocus,
        obscureText: _obscureConfirm,
        onSubmitted: (_) => _submitEmail(),
        decoration: InputDecoration(
          labelText: 'Confirm password',
          suffixIcon: IconButton(
            tooltip: _obscureConfirm ? 'Show password' : 'Hide password',
            icon: Icon(
                _obscureConfirm ? Icons.visibility_off : Icons.visibility),
            onPressed: () =>
                setState(() => _obscureConfirm = !_obscureConfirm),
          ),
        ),
      ),
      if (_createHint != null) ...[
        const SizedBox(height: 8),
        Text(
          _createHint!,
          textAlign: TextAlign.center,
          style: AymaType.sans(size: 12.5, color: ac.fgMute),
        ),
      ],
      const SizedBox(height: 12),
      // Unobtrusive and optional — only in sign-up mode. A friend's invite
      // link (…/r/CODE) shows this same code; pasting the whole link works
      // too (the server normalises it).
      TextField(
        controller: _referral,
        autocorrect: false,
        textCapitalization: TextCapitalization.characters,
        onSubmitted: (_) => _submitEmail(),
        decoration:
            const InputDecoration(labelText: 'Referral code (optional)'),
      ),
    ] else ...[
      const SizedBox(height: 4),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: _forgotPassword,
          child: Text(
            'Forgot password?',
            style: AymaType.sans(size: 13, color: ac.fgMute),
          ),
        ),
      ),
      if (_resetSentTo != null) ...[
        const SizedBox(height: 4),
        Text(
          'Check your email — we sent a reset link to $_resetSentTo.',
          textAlign: TextAlign.center,
          style: AymaType.sans(size: 12.5, color: ac.fgMute),
        ),
      ],
    ],
    const SizedBox(height: 16),
    FilledButton(
      onPressed: _consentsGiven ? _submitEmail : null,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      child: Text(_createMode ? 'Create account' : 'Sign in'),
    ),
    const SizedBox(height: 8),
    // The explicit mode switch — one clear line, whole thing tappable.
    TextButton(
      onPressed: () => setState(() {
        _createMode = !_createMode;
        _resetSentTo = null;
        _createHint = null;
        _confirmPassword.clear();
      }),
      child: Text(
        _createMode
            ? 'Already have an account? Sign in'
            : 'Don’t have an account? Sign up',
        style: AymaType.sans(size: 13, color: ac.fg),
      ),
    ),
  ];

  List<Widget> _phoneForm(AymaTokens ac) {
    final codeStage = _verificationId != null;
    return [
      PhoneNumberField(
        key: _phoneFieldKey,
        controller: _phone,
        enabled: !codeStage,
      ),
      const SizedBox(height: 16),
      if (!codeStage)
        FilledButton(
          onPressed: _consentsGiven ? _sendCode : null,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: const Text('Send code'),
        )
      else ...[
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          onSubmitted: (_) => _confirmCode(),
          decoration: const InputDecoration(labelText: 'SMS code'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _consentsGiven ? _confirmCode : null,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: const Text('Verify'),
        ),
      ],
    ];
  }
}

/// Apple leads as one prominent, solid full-width pill — matches the
/// founder's reference layout, distinct from the compact row below it.
class _AppleBtn extends StatelessWidget {
  const _AppleBtn({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return FilledButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.apple),
      label: const Text('Continue with Apple'),
      style: FilledButton.styleFrom(
        backgroundColor: ac.fg,
        foregroundColor: ac.bg,
        minimumSize: const Size.fromHeight(52),
        textStyle: AymaType.sans(size: 15, weight: FontWeight.w600, color: ac.bg),
      ),
    );
  }
}

/// One of the three equal-width compact buttons (Google / Email / Phone) in
/// a single row — icon above label, since each button is much narrower than
/// the old full-width stacked style.
class _CompactBtn extends StatelessWidget {
  const _CompactBtn({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(64),
        padding: const EdgeInsets.symmetric(vertical: 10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(height: 8),
          Text(label, style: AymaType.sans(size: 12.5, color: ac.fg)),
        ],
      ),
    );
  }
}

/// The two clickwrap checkboxes, each required and unticked by default:
/// (1) 18+ and the Terms (which include use of data for advertising) +
/// Privacy Policy, (2) the face-recognition
/// (biometric) consent, with a link to the full Biometric Information section.
/// Kept separate on purpose — the biometric consent is never folded into the
/// Terms acceptance.
class _ConsentBoxes extends StatefulWidget {
  const _ConsentBoxes({
    required this.termsAccepted,
    required this.biometricAccepted,
    required this.onTerms,
    required this.onBiometric,
  });

  final bool termsAccepted;
  final bool biometricAccepted;
  final ValueChanged<bool> onTerms;
  final ValueChanged<bool> onBiometric;

  @override
  State<_ConsentBoxes> createState() => _ConsentBoxesState();
}

/// One run of a consent sentence: either plain text or a legal link.
class _ConsentSegment {
  const _ConsentSegment.text(this.text)
      : linkKey = null,
        onTap = null;

  const _ConsentSegment.link(this.text,
      {required Key key, required this.onTap})
      : linkKey = key;

  final String text;
  final Key? linkKey;
  final VoidCallback? onTap;

  bool get isLink => linkKey != null;
}

/// State for [_ConsentBoxes]: lays the two rows out under one overlay
/// stack and positions the legal links' tap targets over their words.
///
/// The links used to be [WidgetSpan] chips with 15dp of vertical padding
/// inside the sentences (the NOTE 141 tap-target fix, build 2345): a
/// ~48dp-tall chip stretches every line it sits on, so the consent text
/// rendered with uneven, gappy spacing, the closing full stop wrapped
/// onto a line of its own, and the tile centred each checkbox beside the
/// middle of the inflated block. The labels are plain text spans again,
/// so every line keeps its natural height, and the tiles align their
/// checkboxes with the top of the label — the box sits beside the first
/// line. Each link keeps its 48dp tap target as an invisible overlay rect
/// positioned from the laid-out text (see [_measureLinkTargets]): it can
/// reach past the word without moving any layout, and because the overlay
/// spans both rows, a target that extends past its own row stays
/// tappable instead of being swallowed by the neighbouring row. The
/// overlay's own gesture wins over the row's, so a link tap still opens
/// its page and never changes consent, and taps elsewhere on a row still
/// toggle its checkbox — exactly the NOTE 141 behaviour.
class _ConsentBoxesState extends State<_ConsentBoxes> {
  /// The height of a link tap target (the Material minimum touch target).
  static const double _kTapTargetHeight = 48;

  /// Hit-room above the first row, so a target reaching past the top of
  /// its row stays inside the overlay and tappable. The room comes out of
  /// the gap the screen leaves above the consent rows (24dp there, 6dp
  /// now that 18dp lives here), so the rendered spacing is unchanged.
  static const double _kOverlayTopRoom = 18;

  final GlobalKey _stackKey = GlobalKey();
  final List<GlobalKey> _textKeys = [GlobalKey(), GlobalKey()];

  /// The rows' sentences, rebuilt on every build (fresh tap closures);
  /// [_measureLinkTargets] reads the latest copy after layout.
  List<List<_ConsentSegment>> _rowSegments = const [];

  /// Tap-target rects per link key, in stack coordinates. Filled in once
  /// the labels have been laid out; empty on the very first frame.
  Map<Key, List<Rect>> _linkTargets = const {};
  double? _measuredWidth;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A text-scale or theme change can reflow the labels at the same width.
    _scheduleMeasure();
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _measureLinkTargets());
  }

  /// Measures where each link word landed in its laid-out label and turns
  /// those rects into 48dp-tall tap targets in stack coordinates.
  void _measureLinkTargets() {
    if (!mounted) return;
    final stackBox = _stackKey.currentContext?.findRenderObject();
    if (stackBox is! RenderBox || !stackBox.hasSize) return;
    _measuredWidth = stackBox.size.width;
    final stackOrigin = stackBox.localToGlobal(Offset.zero);
    final targets = <Key, List<Rect>>{};
    for (var row = 0; row < _rowSegments.length; row++) {
      final paragraph = _textKeys[row].currentContext?.findRenderObject();
      if (paragraph is! RenderParagraph || !paragraph.hasSize) continue;
      _measureRow(paragraph, stackOrigin, stackBox.size,
          _rowSegments[row], targets);
    }
    if (!_sameTargets(targets, _linkTargets)) {
      setState(() => _linkTargets = targets);
    }
  }

  void _measureRow(
    RenderParagraph paragraph,
    Offset stackOrigin,
    Size stackSize,
    List<_ConsentSegment> segments,
    Map<Key, List<Rect>> targets,
  ) {
    // Locate every link word in the laid-out paragraph.
    final links = <_ConsentSegment, List<Rect>>{};
    var offset = 0;
    for (final segment in segments) {
      final start = offset;
      offset += segment.text.length;
      if (!segment.isLink) continue;
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: offset),
      );
      links[segment] = [for (final box in boxes) box.toRect()];
    }
    // A target is centred on its word, but the vertical midline between
    // two stacked link words bounds how far each may reach toward the
    // other, so two links' targets never overlap and a tap can never land
    // on the neighbouring link's territory.
    final centers = [
      for (final rects in links.values)
        if (rects.isNotEmpty) rects.first.center.dy,
    ];
    var linkIndex = -1;
    for (final entry in links.entries) {
      if (entry.value.isEmpty) continue;
      linkIndex++;
      final aboveMid = linkIndex > 0
          ? (centers[linkIndex - 1] + centers[linkIndex]) / 2
          : double.negativeInfinity;
      final belowMid = linkIndex < centers.length - 1
          ? (centers[linkIndex] + centers[linkIndex + 1]) / 2
          : double.infinity;
      final rects = <Rect>[];
      for (final word in entry.value) {
        var top = word.center.dy - _kTapTargetHeight / 2;
        if (top + _kTapTargetHeight > belowMid) {
          top = belowMid - _kTapTargetHeight;
        }
        if (top < aboveMid) top = aboveMid;
        // (Link words closer together than a full target cannot both be
        // honoured; the target then rests on the upper midline.)
        final local =
            Rect.fromLTWH(word.left, top, word.width, _kTapTargetHeight);
        final topLeft = paragraph.localToGlobal(local.topLeft) - stackOrigin;
        rects.add(_fitInside(
          Rect.fromLTWH(
              topLeft.dx, topLeft.dy, local.width, local.height),
          Offset.zero & stackSize,
        ));
      }
      targets[entry.key.linkKey!] = rects;
    }
  }

  /// Shifts [rect] the smallest amount that puts it inside [bounds]; a
  /// target bigger than the overlay itself is clipped to the overlay.
  static Rect _fitInside(Rect rect, Rect bounds) {
    var dx = 0.0;
    if (rect.width <= bounds.width) {
      if (rect.left < bounds.left) {
        dx = bounds.left - rect.left;
      } else if (rect.right > bounds.right) {
        dx = bounds.right - rect.right;
      }
    }
    var dy = 0.0;
    if (rect.height <= bounds.height) {
      if (rect.top < bounds.top) {
        dy = bounds.top - rect.top;
      } else if (rect.bottom > bounds.bottom) {
        dy = bounds.bottom - rect.bottom;
      }
    }
    final shifted = rect.shift(Offset(dx, dy));
    return shifted.overlaps(bounds) ? shifted.intersect(bounds) : shifted;
  }

  static bool _sameTargets(Map<Key, List<Rect>> a, Map<Key, List<Rect>> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || other.length != entry.value.length) return false;
      for (var i = 0; i < entry.value.length; i++) {
        if (entry.value[i] != other[i]) return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.bodySmall;
    final linkStyle = base?.copyWith(
      decoration: TextDecoration.underline,
      fontWeight: FontWeight.w600,
    );
    final termsSegments = <_ConsentSegment>[
      const _ConsentSegment.text("I'm 18 or older and I agree to the "),
      _ConsentSegment.link(
        'Terms',
        key: const Key('signin_terms_link'),
        onTap: () => LegalLinks.openTerms(context),
      ),
      const _ConsentSegment.text(
        ' (including use of my data for advertising) and ',
      ),
      _ConsentSegment.link(
        'Privacy Policy',
        key: const Key('signin_privacy_link'),
        onTap: () => LegalLinks.openPrivacy(context),
      ),
      const _ConsentSegment.text('.'),
    ];
    final biometricSegments = <_ConsentSegment>[
      const _ConsentSegment.text(
        'I consent to face recognition. $kBiometricConsentSignInLine ',
      ),
      _ConsentSegment.link(
        'Biometric Information',
        key: const Key('signin_biometric_info_link'),
        onTap: () => context.push(BiometricInfoScreen.path),
      ),
    ];
    _rowSegments = [termsSegments, biometricSegments];

    Widget tile({
      required int row,
      required Key key,
      required bool value,
      required ValueChanged<bool> onChanged,
      required List<_ConsentSegment> segments,
    }) {
      return CheckboxListTile(
        key: key,
        value: value,
        onChanged: (v) => onChanged(v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        dense: true,
        // The checkbox belongs beside the first line of its label, not
        // centred beside the middle of the whole text block: top
        // alignment puts its top at the label top plus
        // minVerticalPadding, so that padding goes to zero too.
        titleAlignment: ListTileTitleAlignment.top,
        minVerticalPadding: 0,
        title: Text.rich(
          TextSpan(
            style: base,
            children: [
              for (final segment in segments)
                TextSpan(
                  text: segment.text,
                  style: segment.isLink ? linkStyle : null,
                ),
            ],
          ),
          key: _textKeys[row],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (_measuredWidth != constraints.maxWidth) _scheduleMeasure();
        return Stack(
          key: _stackKey,
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: _kOverlayTopRoom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  tile(
                    row: 0,
                    key: const Key('signin_terms_checkbox'),
                    value: widget.termsAccepted,
                    onChanged: widget.onTerms,
                    segments: termsSegments,
                  ),
                  tile(
                    row: 1,
                    key: const Key('signin_biometric_checkbox'),
                    value: widget.biometricAccepted,
                    onChanged: widget.onBiometric,
                    segments: biometricSegments,
                  ),
                ],
              ),
            ),
            for (final segments in _rowSegments)
              for (final segment in segments)
                if (segment.isLink)
                  for (var i = 0;
                      i < (_linkTargets[segment.linkKey]?.length ?? 0);
                      i++)
                    Positioned.fromRect(
                      rect: _linkTargets[segment.linkKey]![i],
                      child: Semantics(
                        button: true,
                        label: segment.text,
                        onTap: segment.onTap,
                        child: GestureDetector(
                          key: i == 0 ? segment.linkKey : null,
                          behavior: HitTestBehavior.opaque,
                          onTap: segment.onTap,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
          ],
        );
      },
    );
  }
}
