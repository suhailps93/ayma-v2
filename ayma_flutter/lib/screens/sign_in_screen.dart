import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../services/auth_service.dart';
import '../services/transcript_store.dart';
import '../services/voice_session_controller.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/phone_number_field.dart';
import 'privacy_screen.dart';
import 'splash_screen.dart';
import 'terms_screen.dart';

/// The sign-in gate (§3.3). The app requires a real credential up front — no
/// anonymous browsing — so this is the first screen an unauthenticated user
/// sees. On success it routes to [SplashScreen], which bootstraps and sends the
/// user on to the voice intro / preboarding / main app.
class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    this.auth,
    this.voiceController,
  });

  static const path = '/signin';

  final AuthService? auth;

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

  final _email = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _phoneFieldKey = GlobalKey<PhoneNumberFieldState>();
  String? _verificationId;

  bool get _appleOffered =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    _voice.addListener(_onVoice);
    // Ayma greets while they choose how to sign in. Best-effort — a mic denial
    // or offline just leaves the orb quiet.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.voiceController == null) _voice.start();
    });
  }

  void _onVoice() {
    if (mounted) setState(() {});
  }

  Future<void> _stopVoice() async {
    _voice.removeListener(_onVoice);
    if (widget.voiceController == null && _voice.isActive) {
      await _voice.stop();
    }
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoice);
    if (widget.voiceController == null) {
      _voice.stop();
      _voice.dispose();
    }
    _transcript.dispose();
    _email.dispose();
    _password.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _run(Future<UserCredential> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _stopVoice();
      if (!mounted) return;
      context.go(SplashScreen.path);
    } on FirebaseAuthException catch (e) {
      _snack(_friendly(e));
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled) {
        _snack('Google sign-in failed (${e.code.name}).');
      }
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code != AuthorizationErrorCode.canceled) {
        _snack('Apple sign-in isn’t set up yet.');
      }
    } catch (e) {
      _snack('Sign-in failed. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(FirebaseAuthException e) {
    switch (e.code) {
      case 'wrong-password':
      case 'invalid-credential':
        return 'That email and password don’t match.';
      case 'invalid-email':
        return 'That doesn’t look like an email address.';
      case 'weak-password':
        return 'Pick a password of at least 6 characters.';
      case 'email-already-in-use':
        return 'That email already has an account — sign in instead.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a minute and try again.';
      case 'operation-not-allowed':
        return 'That sign-in method isn’t enabled yet.';
      default:
        return 'Sign-in failed (${e.code}).';
    }
  }

  Future<void> _submitEmail() async {
    if (_email.text.trim().isEmpty || _password.text.length < 6) {
      _snack('Enter an email and a password of at least 6 characters.');
      return;
    }
    await _run(
      () => _auth.signInWithEmailPassword(_email.text, _password.text),
    );
  }

  Future<void> _sendCode() async {
    final field = _phoneFieldKey.currentState;
    if (field == null || !field.isPlausible) {
      _snack('Enter your phone number.');
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
          _snack('Code sent.');
        },
        verificationFailed: (e) {
          if (!mounted) return;
          setState(() => _busy = false);
          _snack(_friendly(e));
        },
        autoSignedIn: (_) async {
          await _stopVoice();
          if (mounted) context.go(SplashScreen.path);
        },
      );
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _snack(_friendly(e));
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
              padding: const EdgeInsets.fromLTRB(28, 40, 28, 32),
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
                            padding: const EdgeInsets.all(30),
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
                              voiceLive: _voice.isActive,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'AYMA',
                      textAlign: TextAlign.center,
                      style: AymaType.mono(
                        size: 12,
                        color: ac.fgMute,
                      ).copyWith(letterSpacing: 6),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Your AI matchmaker',
                      textAlign: TextAlign.center,
                      style: AymaType.serif(size: 26, color: ac.fg),
                    ),
                    const SizedBox(height: 36),
                    if (_stage == _Stage.pick) ..._pick(ac),
                    if (_stage == _Stage.email) ..._emailForm(ac),
                    if (_stage == _Stage.phone) ..._phoneForm(ac),
                    const SizedBox(height: 22),
                    if (_busy)
                      const Center(child: CircularProgressIndicator())
                    else if (_stage != _Stage.pick)
                      TextButton(
                        onPressed: () => setState(() {
                          _stage = _Stage.pick;
                          _verificationId = null;
                        }),
                        child: const Text('Back'),
                      ),
                    const SizedBox(height: 8),
                    _TermsLine(),
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
      _AppleBtn(onTap: () => _run(_auth.signInWithApple)),
      const SizedBox(height: 12),
    ],
    Row(
      children: [
        Expanded(
          child: _CompactBtn(
            icon: Icons.g_mobiledata,
            label: 'Google',
            onTap: () => _run(_auth.signInWithGoogle),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _CompactBtn(
            icon: Icons.mail_outline,
            label: 'Email',
            onTap: () => setState(() => _stage = _Stage.email),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _CompactBtn(
            icon: Icons.phone_outlined,
            label: 'Phone',
            onTap: () => setState(() => _stage = _Stage.phone),
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
    const SizedBox(height: 10),
    TextField(
      controller: _password,
      obscureText: true,
      onSubmitted: (_) => _submitEmail(),
      decoration: const InputDecoration(labelText: 'Password'),
    ),
    const SizedBox(height: 16),
    FilledButton(
      onPressed: _submitEmail,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      child: const Text('Continue'),
    ),
    const SizedBox(height: 6),
    Text(
      'New here? This creates your account.',
      textAlign: TextAlign.center,
      style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
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
          onPressed: _sendCode,
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
          onPressed: _confirmCode,
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
  final VoidCallback onTap;

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
  final VoidCallback onTap;

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
          const SizedBox(height: 4),
          Text(label, style: AymaType.sans(size: 12.5, color: ac.fg)),
        ],
      ),
    );
  }
}

class _TermsLine extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.bodySmall;
    final linkStyle = base?.copyWith(
      decoration: TextDecoration.underline,
      fontWeight: FontWeight.w600,
    );
    return Text.rich(
      TextSpan(
        text: 'By continuing you agree to our ',
        style: base,
        children: [
          TextSpan(
            text: 'Terms',
            style: linkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => context.push(TermsScreen.path),
          ),
          const TextSpan(text: ' and '),
          TextSpan(
            text: 'Privacy Policy',
            style: linkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => context.push(PrivacyScreen.path),
          ),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
