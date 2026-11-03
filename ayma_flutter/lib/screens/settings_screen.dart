import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../build_info.dart';
import '../dev_mode.dart';
import '../services/api_client.dart';
import '../services/profile_service.dart';
import '../services/theme_controller.dart';
import '../services/tour_request.dart';
import '../theme.dart';
import '../widgets/ayma_toast.dart';
import 'accent_color_screen.dart';
import 'biometric_consent_settings_screen.dart';
import 'delete_account_screen.dart';
import 'developer_screen.dart';
import 'main_shell_screen.dart';
import 'notification_prefs_screen.dart';
import 'plan_screen.dart';
import '../widgets/ayma_back_button.dart';

/// Settings (§14.3): plan, appearance (§14.1), pause matching (§14.2)
/// and face verification. Normal users see only a clean release version here;
/// seven taps (or a long-press) on that version row open the hidden Developer
/// panel, whose contents are password-gated. Ayma-behaviour settings (voice, animation, wiki reset) live
/// on `AymaSettingsScreen`; deletion / sign out on their own screens reached
/// from the Profile tab. Notification preferences are reached from here (the
/// Notifications row) and also from the notification centre's bell.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this._controller,
    this.profileService,
    this.api,
    this.imagePicker,
    this.packageInfoOverride,
    this.environmentOverride,
  });

  static const path = '/settings';

  final ThemeController? _controller;
  final ProfileService? profileService;
  final ApiClient? api;
  final ImagePicker? imagePicker;
  final PackageInfo? packageInfoOverride;
  final String? environmentOverride;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ThemeController get _theme => widget._controller ?? themeControllerGlobal;
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final ApiClient _api = widget.api ?? ApiClient();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();

  bool? _verified; // null while loading
  bool _verifying = false;

  /// True while the pause-matching write waits for its server ack.
  bool _pausedSaving = false;

  /// Release version string (e.g. "1.30.0+2264" or "1.30.0+2264 · staging")
  /// from package and build info, shown to users.
  String _version = '';

  /// Taps on the version row, each within [_tapWindow] of the previous one.
  static const _tapsToUnlock = 7;
  static const _tapWindow = Duration(seconds: 2);
  int _buildTaps = 0;
  DateTime? _lastBuildTap;

  void _onBuildTap() {
    // Customer / store builds compile with dev mode off (kDevModeEnabled ==
    // false): the unlock gesture is a complete no-op and the Developer panel
    // is unreachable.
    if (!devModeEnabled) return;
    final now = DateTime.now();
    final last = _lastBuildTap;
    _buildTaps = last != null && now.difference(last) < _tapWindow
        ? _buildTaps + 1
        : 1;
    _lastBuildTap = now;
    if (_buildTaps >= _tapsToUnlock) _openDeveloper();
  }

  void _openDeveloper() {
    if (!devModeEnabled) return;
    _buildTaps = 0;
    _lastBuildTap = null;
    context.push(DeveloperScreen.path);
  }

  @override
  void initState() {
    super.initState();
    _loadVerification();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info =
          widget.packageInfoOverride ?? await PackageInfo.fromPlatform();
      final formatted = formatVersionString(
        version: info.version,
        buildNumber: info.buildNumber,
        environment: widget.environmentOverride,
      );
      if (mounted) setState(() => _version = formatted);
    } catch (_) {
      // Platform package info unavailable (e.g. under widget tests) — leave
      // the row minimal rather than surfacing an error.
    }
  }

  Future<void> _loadVerification() async {
    try {
      final v = await _api.verificationStatus();
      if (mounted) setState(() => _verified = v);
    } catch (_) {
      // Unknown — show neither the badge nor a false "unverified" nudge.
      if (mounted) setState(() => _verified = null);
    }
  }

  /// Front-camera-only capture + `POST /verification/selfie` — the same flow
  /// pre-boarding's verification step uses (§ face verification).
  Future<void> _verifyFace() async {
    if (_verifying) return;
    XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1600,
        imageQuality: 88,
      );
    } catch (_) {
      picked = null;
      if (mounted) {
        AymaToast.show(context, "Couldn't open the camera.",
            kind: AymaToastKind.error);
      }
    }
    if (picked == null || !mounted) return;
    setState(() => _verifying = true);
    try {
      final path = await _profiles.uploadVerificationSelfie(File(picked.path));
      final result = await _api.verifySelfie(path);
      if (!mounted) return;
      if (result.verified) {
        setState(() => _verified = true);
        AymaToast.show(context, "You're verified.",
            kind: AymaToastKind.success);
      } else {
        // The photo itself wasn't usable (moderation rejected it) — the
        // server already tells us that distinctly from a hard failure below
        // (`verified: false` + `reason`, not a thrown exception). Prompt a
        // retry right from the toast rather than making them find the
        // button again.
        AymaToast.show(
          context,
          "That photo couldn't be verified"
          '${result.reason.isNotEmpty ? " (${result.reason})" : ""}'
          '. Try another selfie.',
          kind: AymaToastKind.warning,
          action: AymaToastAction(label: 'Retry', onPressed: _verifyFace),
        );
      }
    } catch (_) {
      // A hard failure (storage upload, network, server error) rather than a
      // rejected photo — never surface the raw exception; just let them
      // capture again.
      if (mounted) {
        AymaToast.show(
          context,
          "Couldn't verify that photo — try again.",
          kind: AymaToastKind.error,
          action: AymaToastAction(label: 'Retry', onPressed: _verifyFace),
        );
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  /// Pause-matching toggle: the switch is stream-driven, so a refused write
  /// reconciles itself (the switch flips back); the toast says why. Catches
  /// internally, so the toast's Retry can safely re-invoke it.
  Future<void> _setPaused(bool value) async {
    if (_pausedSaving) return;
    setState(() => _pausedSaving = true);
    try {
      await _profiles.setPaused(value);
    } catch (e) {
      if (!mounted) return;
      AymaToast.show(context, 'Could not save ($e).',
          kind: AymaToastKind.error,
          action: AymaToastAction(
              label: 'Retry', onPressed: () => _setPaused(value)));
    } finally {
      if (mounted) setState(() => _pausedSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Settings')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Plan',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          ListTile(
            key: const ValueKey('settings-plan'),
            leading: Icon(Icons.workspace_premium_outlined, color: ac.fgDim),
            title: Text('Plan and credits',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Your plan, credits left and where they went',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(PlanScreen.path),
          ),
          Divider(color: ac.lineSoft),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('Appearance',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          AnimatedBuilder(
            animation: _theme,
            builder: (context, _) => RadioGroup<ThemeMode>(
              groupValue: _theme.mode,
              onChanged: (m) => _theme.set(m!),
              child: Column(
                children: [
                  for (final mode in ThemeMode.values)
                    RadioListTile<ThemeMode>(
                      value: mode,
                      title: Text(_label(mode),
                          style: AymaType.sans(size: 15, color: ac.fg)),
                    ),
                ],
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.palette_outlined, color: ac.accent),
            title: Text('Accent Color',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Cherry Fuchsia by default — pick your own.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(AccentColorScreen.path),
          ),
          Divider(color: ac.lineSoft),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('Matching',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          StreamBuilder<bool>(
            stream: _profiles.watchPaused(),
            builder: (context, snap) {
              final paused = snap.data ?? false;
              return SwitchListTile(
                title: Text('Pause matching',
                    style: AymaType.sans(size: 15, color: ac.fg)),
                subtitle: Text(
                    'You won’t appear in Explore or new match sourcing.',
                    style: AymaType.sans(
                        size: 12, soft: true, color: ac.fgMute)),
                value: paused,
                onChanged: _pausedSaving ? null : _setPaused,
              );
            },
          ),
          Divider(color: ac.lineSoft),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('Notifications',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          ListTile(
            key: const ValueKey('settings-notifications'),
            leading: Icon(Icons.notifications_outlined, color: ac.fgDim),
            title: Text('Notification preferences',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Choose what Ayma can notify you about.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(NotificationPrefsScreen.path),
          ),
          Divider(color: ac.lineSoft),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('Privacy',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          StreamBuilder<bool>(
            stream: _profiles.watchAiAvatar(),
            builder: (context, snap) => SwitchListTile(
              key: const Key('settings_ai_avatar'),
              title: Text('AI Avatar',
                  style: AymaType.sans(size: 15, color: ac.fg)),
              subtitle: Text(
                'Allow an AI version of me. Ayma builds an AI agent from your '
                'profile for simulated dates and agent features. Turn off to '
                'opt out: you can’t run simulated dates, and no one can '
                'simulate one with you.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
              ),
              value: snap.data ?? true,
              onChanged: (v) => _profiles.setAiAvatar(v),
            ),
          ),
          Divider(color: ac.lineSoft),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('Verification',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          if (_verified == true)
            ListTile(
              leading: const Icon(Icons.verified_outlined,
                  color: AymaColors.success),
              title: Text('Face verified',
                  style: AymaType.sans(size: 15, color: ac.fg)),
              subtitle: Text(
                'Your verification selfie is never shown on your profile.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
              ),
            )
          else if (_verified == false)
            ListTile(
              leading: Icon(Icons.gpp_maybe_outlined, color: ac.fgMute),
              title: Text('Verify your face',
                  style: AymaType.sans(size: 15, color: ac.fg)),
              subtitle: Text(
                'One quick selfie confirms it\'s really you — never shown '
                'on your profile.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
              ),
              trailing: _verifying
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_right),
              onTap: _verifying ? null : _verifyFace,
            ),
          ListTile(
            key: const Key('settings_biometric_consent'),
            leading: Icon(Icons.face_retouching_natural_outlined,
                color: ac.fgMute),
            title: Text('Face matching consent',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text(
              'See what you agreed to, or withdraw it (this deletes your '
              'face data and your account).',
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
            ),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(BiometricConsentSettingsScreen.path),
          ),
          Divider(color: ac.lineSoft),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('Help',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          ListTile(
            key: const ValueKey('settings-feature-tour'),
            leading: Icon(Icons.explore_outlined, color: ac.fgDim),
            title: Text('How to use Ayma',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Replay the feature tour any time.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            // Full replay on demand (not a spotlight): the interactive
            // coach-mark tour runs over the live shell, so return to it and ask
            // it to run the full walkthrough (re-marks every feature seen —
            // harmless, they've now seen them again).
            onTap: () {
              TourRequest.instance.requestFull();
              context.go(MainShellScreen.path);
            },
          ),
          Divider(color: ac.lineSoft),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text('Account',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: ac.error),
            title: Text('Delete account',
                style: AymaType.sans(size: 15, color: ac.error)),
            subtitle: Text('Permanently remove your data after 30 days.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(DeleteAccountScreen.path),
          ),
          Divider(color: ac.lineSoft),
          const SizedBox(height: 24),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: GestureDetector(
                key: const ValueKey('build-stamp'),
                behavior: HitTestBehavior.opaque,
                onTap: _onBuildTap,
                onLongPress: _openDeveloper,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    _version.isEmpty ? 'Version' : 'Version $_version',
                    style: AymaType.sans(size: 12, color: ac.fgMute),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _label(ThemeMode m) => switch (m) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'Match system',
      };
}
