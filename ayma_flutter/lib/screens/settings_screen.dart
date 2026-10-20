import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../build_info.dart';
import '../services/api_client.dart';
import '../services/profile_service.dart';
import '../services/theme_controller.dart';
import '../theme.dart';
import 'accent_color_screen.dart';
import 'release_notes_screen.dart';
import '../widgets/ayma_back_button.dart';

/// User settings (§14.3): appearance (§14.1), pause matching (§14.2) and face
/// verification. Ayma-behaviour settings (voice, animation, wiki reset) live
/// on `AymaSettingsScreen`; deletion / sign out / notifications on their own
/// screens reached from the Profile tab.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this._controller,
    this.profileService,
    this.api,
    this.imagePicker,
  });

  static const path = '/settings';

  final ThemeController? _controller;
  final ProfileService? profileService;
  final ApiClient? api;
  final ImagePicker? imagePicker;

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

  @override
  void initState() {
    super.initState();
    _loadVerification();
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open the camera.")),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("You're verified.")),
        );
      } else {
        // The photo itself wasn't usable (moderation rejected it) — the
        // server already tells us that distinctly from a hard failure below
        // (`verified: false` + `reason`, not a thrown exception). Prompt a
        // retry right from the snackbar rather than making them find the
        // button again.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            "That photo couldn't be verified"
            '${result.reason.isNotEmpty ? " (${result.reason})" : ""}'
            '. Try another selfie.',
          ),
          action: SnackBarAction(label: 'Retry', onPressed: _verifyFace),
        ));
      }
    } catch (_) {
      // A hard failure (storage upload, network, server error) rather than a
      // rejected photo — never surface the raw exception; just let them
      // capture again.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text("Couldn't verify that photo — try again."),
          action: SnackBarAction(label: 'Retry', onPressed: _verifyFace),
        ));
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('User settings')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                onChanged: (v) => _profiles.setPaused(v),
              );
            },
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
          Divider(color: ac.lineSoft),
          const SizedBox(height: 24),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: InkWell(
                onTap: () => context.push(ReleaseNotesScreen.path),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Build  $appBuildTag',
                        style: AymaType.mono(size: 10, color: ac.fgMute)
                            .copyWith(letterSpacing: 0.5),
                      ),
                      Icon(Icons.chevron_right, size: 14, color: ac.fgMute),
                    ],
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
