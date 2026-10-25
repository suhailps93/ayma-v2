import 'package:flutter/material.dart';

import '../legal/biometric_consent_text.dart';
import '../services/api_client.dart';
import '../services/biometric_consent.dart';
import '../theme.dart';
import 'markdown_text.dart';

/// The face-matching consent: the plain-language explanation, a required
/// checkbox and an "I agree" button that records the consent server-side
/// (`POST /biometric-consent`). Separate from the Terms. There is no decline
/// button — the consent is required to use Ayma. [onAgreed] runs
/// once the server has stored the consent.
class BiometricConsentPanel extends StatefulWidget {
  const BiometricConsentPanel({
    super.key,
    required this.api,
    required this.onAgreed,
    this.region,
  });

  final ApiClient api;
  final VoidCallback onAgreed;

  /// Device country code override for tests; defaults to [deviceRegionCode].
  final String? region;

  @override
  State<BiometricConsentPanel> createState() => _BiometricConsentPanelState();
}

class _BiometricConsentPanelState extends State<BiometricConsentPanel> {
  bool _checked = false;
  bool _saving = false;
  String? _error;

  Future<void> _agree() async {
    if (!_checked || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.acceptBiometricConsent(
        region: widget.region ?? deviceRegionCode(),
      );
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
          onPressed: _checked && !_saving ? _agree : null,
          child: _saving
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('I agree'),
        ),
      ],
    );
  }
}
