import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../widgets/biometric_consent_panel.dart';
import 'splash_screen.dart';

/// One-time face-matching consent, only for an existing account with no
/// consent record (created before the sign-in page asked for it, or after a
/// consent-version bump). New accounts give it on the sign-in page. Reached
/// from the splash routing or whenever the API answers
/// `biometric_consent_required`. It also asks for the (updated) Terms and
/// Privacy Policy acceptance, so a version bump doubles as the Terms
/// re-acceptance. It has exactly one action: "I agree".
/// Withdrawal lives in Settings.
class BiometricConsentScreen extends StatefulWidget {
  const BiometricConsentScreen({super.key, this.api});

  static const path = '/consent';

  final ApiClient? api;

  @override
  State<BiometricConsentScreen> createState() => _BiometricConsentScreenState();
}

class _BiometricConsentScreenState extends State<BiometricConsentScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
            children: [
              BiometricConsentPanel(
                api: _api,
                requireTerms: true,
                onAgreed: () => context.go(SplashScreen.path),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
