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
import 'splash_screen.dart';
import 'terms_screen.dart';

/// The sign-in gate (§3.3). The app requires a real credential up front — no
/// anonymous browsing — so this is the first screen an unauthenticated user
/// sees. On success it routes to [SplashScreen], which bootstraps and sends the
/// user on to the voice intro / preboarding / main app.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, this.auth, this.voiceController});

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
  late final VoiceSessionController _voice = widget.voiceController ??
      VoiceSessionController(transcriptStore: _transcript, welcome: true);

  _Stage _stage = _Stage.pick;
  bool _busy = false;

  final _email = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
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
    await _run(() =>
        _auth.signInWithEmailPassword(_email.text, _password.text));
  }

  Future<void> _sendCode() async {
    final phone = _phone.text.trim();
    if (!phone.startsWith('+') || phone.length < 8) {
      _snack('Enter your number in +country format, e.g. +15551234567.');
      return;
    }
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
                        onTap: () => _voice.isActive
                            ? _voice.stop()
                            : _voice.start(),
                        child: AymaOrb(
                          size: 76,
                          active: _voice.isActive,
                          state: _voice.agentSpeaking
                              ? OrbState.speaking
                              : (_voice.phase == VoiceSessionPhase.connecting
                                  ? OrbState.thinking
                                  : (_voice.isActive
                                      ? OrbState.listening
                                      : OrbState.idle)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text('AYMA',
                        textAlign: TextAlign.center,
                        style: AymaType.mono(size: 12, color: ac.fgMute)
                            .copyWith(letterSpacing: 6)),
                    const SizedBox(height: 10),
                    Text('Your AI matchmaker',
                        textAlign: TextAlign.center,
                        style: AymaType.serif(size: 26, color: ac.fg)),
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
        _Btn(
          icon: Icons.g_mobiledata,
          label: 'Continue with Google',
          onTap: () => _run(_auth.signInWithGoogle),
        ),
        if (_appleOffered)
          _Btn(
            icon: Icons.apple,
            label: 'Continue with Apple',
            onTap: () => _run(_auth.signInWithApple),
          ),
        _Btn(
          icon: Icons.mail_outline,
          label: 'Continue with email',
          onTap: () => setState(() => _stage = _Stage.email),
        ),
        _Btn(
          icon: Icons.phone_outlined,
          label: 'Continue with phone',
          onTap: () => setState(() => _stage = _Stage.phone),
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
        Text('New here? This creates your account.',
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
      ];

  List<Widget> _phoneForm(AymaTokens ac) {
    final codeStage = _verificationId != null;
    return [
      TextField(
        controller: _phone,
        keyboardType: TextInputType.phone,
        enabled: !codeStage,
        decoration: const InputDecoration(
          labelText: 'Phone number',
          hintText: '+15551234567',
        ),
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

class _Btn extends StatelessWidget {
  const _Btn({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon),
        label: Align(alignment: Alignment.centerLeft, child: Text(label)),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      ),
    );
  }
}

class _TermsLine extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.bodySmall;
    return Text.rich(
      TextSpan(
        text: 'By continuing you agree to our ',
        style: base,
        children: [
          TextSpan(
            text: 'Terms',
            style: base?.copyWith(
              decoration: TextDecoration.underline,
              fontWeight: FontWeight.w600,
            ),
            recognizer: TapGestureRecognizer()
              ..onTap = () => context.push(TermsScreen.path),
          ),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
