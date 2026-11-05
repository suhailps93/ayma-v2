import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../legal/biometric_consent_text.dart';
import '../services/api_client.dart';
import '../services/biometric_consent.dart';
import '../services/push_service.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_wing_loader.dart';
import '../widgets/markdown_text.dart';
import 'sign_in_screen.dart';

/// Settings > Face matching: shows the consent the member gave (and when),
/// and lets them withdraw it. Ayma can't run without it, so withdrawing
/// deletes the face data immediately and then deletes the account
/// (`POST /biometric-consent/withdraw`); signing out is offered as the
/// alternative.
class BiometricConsentSettingsScreen extends StatefulWidget {
  const BiometricConsentSettingsScreen({
    super.key,
    this.api,
    this.auth,
    this.clearPushToken,
  });

  static const path = '/settings/biometric-consent';

  final ApiClient? api;
  final FirebaseAuth? auth;

  /// Defaults to [PushService.clearToken]; injectable for tests.
  final Future<void> Function()? clearPushToken;

  @override
  State<BiometricConsentSettingsScreen> createState() =>
      _BiometricConsentSettingsScreenState();
}

class _BiometricConsentSettingsScreenState
    extends State<BiometricConsentSettingsScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  BiometricConsentStatus? _status;
  bool _loadFailed = false;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await _api.biometricConsentStatus();
      if (mounted) setState(() => _status = s);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  static String _date(DateTime d) {
    final l = d.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')}';
  }

  Future<void> _signOut() async {
    try {
      await (widget.clearPushToken ?? PushService().clearToken)();
      await (widget.auth ?? FirebaseAuth.instance).signOut();
    } catch (_) {
      if (mounted) {
        setState(() => _error = "Couldn't sign out. Close and reopen the app.");
      }
      return;
    }
    BiometricConsentState.instance.clear();
    if (mounted) context.go(SignInScreen.path);
  }

  Future<void> _withdraw() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Withdraw consent and delete your account?'),
        content: const Text(
          'Ayma needs face matching to work, so withdrawing deletes your face '
          'data right away and then deletes your account: your profile, '
          'photos, messages and everything Ayma learned. You can recover the '
          'account by signing back in within 30 days, but you would need to '
          'give this consent again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('biometric_withdraw_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Withdraw and delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await _api.withdrawBiometricConsent();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error =
            "Couldn't withdraw your consent. Check your connection and "
            'try again.';
      });
      return;
    }
    await _signOut();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text(kBiometricConsentTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          if (status != null && status.consented)
            Text(
              status.consentedAt != null
                  ? 'You agreed on ${_date(status.consentedAt!)}.'
                  : 'You have agreed to face matching.',
              key: const Key('biometric_consent_given'),
              style: AymaType.sans(size: 15, color: ac.fg),
            )
          else if (_loadFailed)
            Text(
              "Couldn't load your consent right now.",
              style: AymaType.sans(size: 15, color: ac.fgMute),
            ),
          const SizedBox(height: 16),
          MarkdownText(
            kBiometricConsentText.trim(),
            style: AymaType.sans(size: 14, color: ac.fg, height: 1.5),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: AymaType.sans(size: 13, color: AymaColors.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('biometric_withdraw'),
            style: FilledButton.styleFrom(backgroundColor: ac.error),
            onPressed: _working ? null : _withdraw,
            // Consent-withdrawal (+ face-data + account delete) in flight.
            child: _working
                ? const AymaWingLoader(size: 20, showLabel: false)
                : const Text('Withdraw consent and delete my account'),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('biometric_sign_out'),
            onPressed: _working ? null : _signOut,
            child: const Text('Sign out instead'),
          ),
        ],
      ),
    );
  }
}
