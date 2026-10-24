import 'package:shared_preferences/shared_preferences.dart';

/// Local memory of when the trial paywall was last shown, so the out-of-credits
/// flow shows it at most once per day per device and the onboarding paywall
/// shows once per account. Storage failures read as "already shown": the
/// paywall is a nudge, never something to repeat when we can't remember it.
class TrialPaywallGate {
  const TrialPaywallGate();

  static const _dailyKey = 'trial_paywall_last_shown_day';
  static const _onboardingPrefix = 'onboarding_paywall_seen_';

  static String dayKey(DateTime now) {
    final d = now.toLocal();
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  /// True when the out-of-credits trial paywall has not yet been shown today.
  Future<bool> dailyDue(DateTime now) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_dailyKey) != dayKey(now);
    } catch (_) {
      return false;
    }
  }

  Future<void> markDailyShown(DateTime now) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dailyKey, dayKey(now));
    } catch (_) {/* best-effort */}
  }

  /// True when the onboarding paywall was never shown to [uid] on this device.
  Future<bool> onboardingDue(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return !(prefs.getBool('$_onboardingPrefix$uid') ?? false);
    } catch (_) {
      return false;
    }
  }

  Future<void> markOnboardingShown(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_onboardingPrefix$uid', true);
    } catch (_) {/* best-effort */}
  }
}
