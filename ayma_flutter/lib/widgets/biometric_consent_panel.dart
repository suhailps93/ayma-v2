import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../legal/biometric_consent_text.dart';
import '../screens/privacy_screen.dart';
import '../screens/terms_screen.dart';
import '../services/api_client.dart';
import '../services/biometric_consent.dart';
import '../theme.dart';
import 'ayma_wing_loader.dart';
import 'markdown_text.dart';

/// The face-matching consent: the plain-language explanation, a required
/// checkbox and an "I agree" button that records the consent server-side
/// (`POST /biometric-consent`). Separate from the Terms. There is no decline
/// button — the consent is required to use Ayma. [onAgreed] runs
/// once the server has stored the consent.
///
/// With [requireTerms] (the one-time screen existing accounts see after a
/// consent-version bump) it also shows a separate, required checkbox to accept
/// the updated Terms and Privacy Policy; "I agree" needs both boxes.
class BiometricConsentPanel extends StatefulWidget {
  const BiometricConsentPanel({
    super.key,
    required this.api,
    required this.onAgreed,
    this.region,
    this.requireTerms = false,
  });

  final ApiClient api;
  final VoidCallback onAgreed;

  /// Device country code override for tests; defaults to [deviceRegionCode].
  final String? region;

  /// Also require accepting the updated Terms and Privacy Policy.
  final bool requireTerms;

  @override
  State<BiometricConsentPanel> createState() => _BiometricConsentPanelState();
}

class _BiometricConsentPanelState extends State<BiometricConsentPanel> {
  bool _checked = false;
  bool _termsChecked = false;
  bool _saving = false;
  String? _error;

  bool get _canAgree => _checked && (!widget.requireTerms || _termsChecked);

  Future<void> _agree() async {
    if (!_canAgree || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.acceptBiometricConsent(
        region: widget.region ?? deviceRegionCode(),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409) {
        // The account is soft-deleted: consent can't be recorded until it is
        // recovered (B9, §3.6). Signal recovery — the router redirects to the
        // recovery screen — instead of the misleading "check your connection".
        RecoveryRequiredState.instance.markRequired();
        setState(() => _saving = false);
        return;
      }
      setState(() {
        _saving = false;
        _error =
            "Couldn't save your consent. Check your connection and try "
            'again.';
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error =
            "Couldn't save your consent. Check your connection and try "
            'again.';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onAgreed();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      key: const Key('biometric_consent_panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          kBiometricConsentTitle,
          style: AymaType.serif(size: 24, color: ac.fg),
        ),
        const SizedBox(height: 12),
        MarkdownText(
          kBiometricConsentText.trim(),
          style: AymaType.sans(size: 14, color: ac.fg, height: 1.5),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          key: const Key('biometric_consent_checkbox'),
          value: _checked,
          onChanged: _saving
              ? null
              : (v) => setState(() => _checked = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(
            kBiometricConsentCheckbox,
            style: AymaType.sans(size: 14, color: ac.fg),
          ),
        ),
        if (widget.requireTerms) _termsBox(context),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: AymaType.sans(size: 13, color: AymaColors.error),
          ),
        ],
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('biometric_consent_agree'),
          onPressed: _canAgree && !_saving ? _agree : null,
          // POST /biometric-consent in flight — button slot, wings only.
          child: _saving
              ? const AymaWingLoader(size: 20, showLabel: false)
              : const Text('I agree'),
        ),
      ],
    );
  }

  Widget _termsBox(BuildContext context) {
    final ac = context.ac;
    final base = AymaType.sans(size: 14, color: ac.fg);
    final linkStyle = base.copyWith(
      decoration: TextDecoration.underline,
      fontWeight: FontWeight.w600,
    );
    TextSpan link(String text, String path) => TextSpan(
          text: text,
          style: linkStyle,
          recognizer: TapGestureRecognizer()..onTap = () => context.push(path),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          "We've updated our Terms and Privacy Policy. They now cover our "
          'plan to show ads and use your data for advertising (no ads are '
          "shown yet), and that Ayma isn't end-to-end encrypted.",
          style: AymaType.sans(size: 14, color: ac.fg, height: 1.5)
              .copyWith(fontWeight: FontWeight.w700),
        ),
        CheckboxListTile(
          key: const Key('consent_terms_checkbox'),
          value: _termsChecked,
          onChanged: _saving
              ? null
              : (v) => setState(() => _termsChecked = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text.rich(
            TextSpan(
              text: "I'm 18 or older and I agree to the updated ",
              style: base,
              children: [
                link('Terms', TermsScreen.path),
                const TextSpan(
                  text: ' (including use of my data for advertising) and ',
                ),
                link('Privacy Policy', PrivacyScreen.path),
                const TextSpan(text: '.'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
