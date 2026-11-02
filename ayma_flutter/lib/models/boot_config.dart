class BootConfig {
  final String uid;
  final String sessionMode; // 'active', 'interview', 'marketing'
  final String entryRoute; // '/', '/preboarding', '/chat'
  final int cachedAtEpochMs;

  // Advisory hints only — not client authorization gates!
  final bool biometricConsentRequiredHint;
  final bool ageBlockedHint;
  final bool recoveryRequiredHint;

  const BootConfig({
    required this.uid,
    required this.sessionMode,
    required this.entryRoute,
    required this.cachedAtEpochMs,
    this.biometricConsentRequiredHint = false,
    this.ageBlockedHint = false,
    this.recoveryRequiredHint = false,
  });

  bool get isStale {
    final ageMs = DateTime.now().millisecondsSinceEpoch - cachedAtEpochMs;
    return ageMs > const Duration(days: 7).inMilliseconds;
  }

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'session_mode': sessionMode,
        'entry_route': entryRoute,
        'cached_at': cachedAtEpochMs,
        'biometric_consent_hint': biometricConsentRequiredHint,
        'age_blocked_hint': ageBlockedHint,
        'recovery_required_hint': recoveryRequiredHint,
      };

  factory BootConfig.fromJson(Map<String, dynamic> json) => BootConfig(
        uid: json['uid'] as String,
        sessionMode: json['session_mode'] as String? ?? 'active',
        entryRoute: json['entry_route'] as String? ?? '/',
        cachedAtEpochMs: json['cached_at'] as int? ?? 0,
        biometricConsentRequiredHint: json['biometric_consent_hint'] == true,
        ageBlockedHint: json['age_blocked_hint'] == true,
        recoveryRequiredHint: json['recovery_required_hint'] == true,
      );
}
