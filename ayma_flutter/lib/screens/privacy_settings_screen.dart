import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/legal_links.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_wing_loader.dart';
import 'biometric_consent_settings_screen.dart';
import 'delete_account_screen.dart';

/// Privacy: everything privacy-related under the single Privacy row on
/// Settings (founder cleanup, 2026-11-07): pause matching (pulled in
/// from its own top-level section), the AI-avatar opt-out, face
/// verification, face matching consent, Terms of Service and Privacy Policy,
/// wiping what Ayma has learned (directly above Delete account) and Delete
/// account itself. Handlers and prefs are unchanged — this is regrouping only.
class PrivacySettingsScreen extends StatefulWidget {
  const PrivacySettingsScreen({
    super.key,
    this.profileService,
    this.api,
    this.imagePicker,
  });

  static const path = '/settings/privacy';

  final ProfileService? profileService;
  final ApiClient? api;
  final ImagePicker? imagePicker;

  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final ApiClient _api = widget.api ?? ApiClient();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();

  bool? _verified; // null while loading
  bool _verifying = false;

  /// True while the pause-matching write waits for its server ack.
  bool _pausedSaving = false;

  bool _resetting = false;

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

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Wipe what Ayma has learned?'),
        content: const Text(
          'This clears your wiki and conversation history. Your account, '
          'profile and photos stay. This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Wipe')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _resetting = true);
    try {
      await _api.resetWiki();
      if (mounted) {
        AymaToast.show(context, 'Ayma’s memory of you has been cleared.',
            kind: AymaToastKind.success);
      }
    } catch (e) {
      if (mounted) {
        AymaToast.show(context, 'Could not reset ($e).',
            kind: AymaToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
          leading: const AymaBackButton(), title: const Text('Privacy')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 20),
        children: [
          const SizedBox(height: 8),
          StreamBuilder<bool>(
            stream: _profiles.watchPaused(),
            builder: (context, snap) {
              final paused = snap.data ?? false;
              return SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                secondary: Icon(Icons.pause_circle_outlined, color: ac.fgDim),
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
          StreamBuilder<bool>(
            stream: _profiles.watchAiAvatar(),
            builder: (context, snap) => SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              secondary: Icon(Icons.smart_toy_outlined, color: ac.fgDim),
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
          if (_verified == true)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: Icon(Icons.verified_outlined,
                  color: ac.successText),
              title: Text('Face verified',
                  style: AymaType.sans(size: 15, color: ac.fg)),
              subtitle: Text(
                'Your verification selfie is never shown on your profile.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
              ),
            )
          else if (_verified == false)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: Icon(Icons.gpp_maybe_outlined, color: ac.fgDim),
              title: Text('Verify your face',
                  style: AymaType.sans(size: 15, color: ac.fg)),
              subtitle: Text(
                'One quick selfie confirms it\'s really you — never shown '
                'on your profile.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
              ),
              // Selfie capture + POST /verification/selfie in flight.
              trailing: _verifying
                  ? const AymaWingLoader(size: 18, showLabel: false)
                  : Icon(Icons.chevron_right, color: ac.fgMute),
              onTap: _verifying ? null : _verifyFace,
            ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            key: const Key('settings_biometric_consent'),
            leading: Icon(Icons.face_retouching_natural_outlined,
                color: ac.fgDim),
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
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            key: const Key('settings_terms'),
            leading: Icon(Icons.description_outlined, color: ac.fgDim),
            title: Text('Terms of Service',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text(
              'How Ayma uses your photos and public information',
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
            ),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => LegalLinks.openTerms(context),
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            key: const Key('settings_privacy_policy'),
            leading: Icon(Icons.privacy_tip_outlined, color: ac.fgDim),
            title: Text('Privacy Policy',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text(
              'What we collect, why, and your choices',
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
            ),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => LegalLinks.openPrivacy(context),
          ),
          Divider(color: ac.lineSoft),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: Icon(Icons.delete_sweep_outlined, color: ac.error),
            title: Text('Wipe what Ayma has learned',
                style: AymaType.sans(size: 15, color: ac.errorText)),
            subtitle: Text('Clears your wiki + history; keeps your account.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            // Wiki/history wipe in flight — trailing slot, wings only.
            trailing: _resetting
                ? const AymaWingLoader(size: 18, showLabel: false)
                : null,
            onTap: _resetting ? null : _confirmReset,
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: Icon(Icons.delete_outline, color: ac.error),
            title: Text('Delete account',
                style: AymaType.sans(size: 15, color: ac.errorText)),
            subtitle: Text('Permanently remove your data after 30 days.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(DeleteAccountScreen.path),
          ),
        ],
      ),
    );
  }
}
