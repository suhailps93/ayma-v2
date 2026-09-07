import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'terms_screen.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../services/auth_link_service.dart';

/// Credential picker (Step 5).
///
/// Google / Apple / Phone / Email. Selecting one links a real credential onto
/// the current anonymous session in place (§3.1, §3.3) — the `uid` does not
/// change. This screen is later folded into the preboarding sequence as one of
/// its steps (§3.3); for now it's reachable on its own for testing.
class CredentialPickerScreen extends StatefulWidget {
  const CredentialPickerScreen({super.key, this.linkService});

  static const path = '/link';

  final AuthLinkService? linkService;

  @override
  State<CredentialPickerScreen> createState() => _CredentialPickerScreenState();
}

class _CredentialPickerScreenState extends State<CredentialPickerScreen> {
  late final AuthLinkService _link = widget.linkService ?? AuthLinkService();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _showEmailForm = false;
  bool _busy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<UserCredential> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await action();
      if (!mounted) return;
      final providers = result.user?.providerData
              .map((p) => p.providerId)
              .join(', ') ??
          '';
      _snack('Linked (uid ${result.user?.uid}) — providers: $providers');
      context.go('/');
    } on FirebaseAuthException catch (e) {
      _snack('Link failed: ${e.code}${e.message != null ? ' — ${e.message}' : ''}');
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled) {
        _snack('Google sign-in failed: ${e.code.name}');
      }
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code != AuthorizationErrorCode.canceled) {
        _snack('Apple sign-in failed: ${e.code.name}');
      }
    } catch (e) {
      _snack('Link failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submitEmail() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.length < 6) {
      _snack('Enter an email and a password of at least 6 characters.');
      return;
    }
    await _run(() => _link.linkEmailPassword(email, password));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose how to sign in')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _ProviderButton(
              icon: Icons.g_mobiledata,
              label: 'Continue with Google',
              onPressed: () => _run(_link.linkGoogle),
            ),
            _ProviderButton(
              icon: Icons.apple,
              label: 'Continue with Apple',
              onPressed: () => _run(_link.linkApple),
            ),
            _ProviderButton(
              icon: Icons.phone,
              label: 'Continue with phone',
              onPressed: () => context.push(_PhoneLinkScreen.path, extra: _link),
            ),
            _ProviderButton(
              icon: Icons.mail_outline,
              label: 'Continue with email',
              onPressed: () => setState(() => _showEmailForm = !_showEmailForm),
            ),
            if (_showEmailForm) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _submitEmail,
                child: const Text('Link email'),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
            ],
            const SizedBox(height: 20),
            const _TermsLine(),
          ],
        ),
      ),
    );
  }
}

/// "By continuing you agree to our Terms." — the Terms word taps through to
/// [TermsScreen]. Continuing counts as agreement (no checkbox).
class _TermsLine extends StatelessWidget {
  const _TermsLine();

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

class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Align(
          alignment: Alignment.centerLeft,
          child: Text(label),
        ),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
        ),
      ),
    );
  }
}

/// Phone-number entry + SMS-code confirmation for phone linking.
class _PhoneLinkScreen extends StatefulWidget {
  const _PhoneLinkScreen({required this.linkService});

  static const path = '/link/phone';

  final AuthLinkService linkService;

  @override
  State<_PhoneLinkScreen> createState() => _PhoneLinkScreenState();
}

class _PhoneLinkScreenState extends State<_PhoneLinkScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  String? _verificationId;
  bool _busy = false;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _sendCode() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      _snack('Enter a phone number in +country format.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.linkService.startPhoneLink(
        phone,
        codeSent: (verificationId) {
          if (!mounted) return;
          setState(() {
            _verificationId = verificationId;
            _busy = false;
          });
          _snack('Code sent.');
        },
        verificationFailed: (e) {
          if (!mounted) return;
          setState(() => _busy = false);
          _snack('Verification failed: ${e.code}');
        },
        autoLinked: (_) {
          if (!mounted) return;
          _snack('Phone linked.');
          context.go('/');
        },
      );
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _snack('Verification failed: ${e.code}');
      }
    }
  }

  Future<void> _confirm() async {
    final id = _verificationId;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      final result =
          await widget.linkService.confirmPhoneCode(id, _codeController.text);
      if (!mounted) return;
      _snack('Phone linked (uid ${result.user?.uid}).');
      context.go('/');
    } on FirebaseAuthException catch (e) {
      _snack('Link failed: ${e.code}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final codeStage = _verificationId != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Continue with phone')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              enabled: !codeStage,
              decoration: const InputDecoration(
                labelText: 'Phone number',
                hintText: '+15551234567',
              ),
            ),
            const SizedBox(height: 12),
            if (!codeStage)
              FilledButton(
                onPressed: _sendCode,
                child: const Text('Send code'),
              ),
            if (codeStage) ...[
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'SMS code'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _confirm,
                child: const Text('Verify & link'),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
    );
  }
}

/// Route builder for the phone sub-screen (registered in app_router.dart).
Widget buildPhoneLinkScreen(Object? extra) =>
    _PhoneLinkScreen(linkService: extra as AuthLinkService? ?? AuthLinkService());
