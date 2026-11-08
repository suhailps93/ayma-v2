import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../build_info.dart';
import '../dev_mode.dart';
import '../services/chat_inbox.dart';
import '../services/tour_anchors.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import 'appearance_settings_screen.dart';
import 'connect_agent_screen.dart';
import 'developer_screen.dart';
import 'main_shell_screen.dart';
import 'notification_prefs_screen.dart';
import 'plan_screen.dart';
import 'privacy_settings_screen.dart';
import 'voice_preference_screen.dart';

/// Settings (§14.3), cleaned up per the founder (2026-11-07): the top
/// level is four section rows — Plan and credits (unchanged),
/// Appearance (theme mode + accent colour), Notification preferences
/// and Privacy (pause matching, AI avatar, face verification, face
/// matching consent, wipe, delete account) — plus two plain Ayma line
/// items, Ayma's models and Connect an agent, and the How to use Ayma guided-tour tile. There is no separate
/// "Ayma settings" page any more; everything the old sections held
/// lives inside one of the four sections with its handlers unchanged.
/// Normal users see only a clean release version at the bottom; seven
/// taps (or a long-press) on that version row open the hidden Developer
/// panel, whose contents are password-gated.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.packageInfoOverride,
    this.environmentOverride,
  });

  static const path = '/settings';

  final PackageInfo? packageInfoOverride;
  final String? environmentOverride;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
          leading: const AymaBackButton(), title: const Text('Settings')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
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
          KeyedSubtree(
            key: TourAnchors.keyFor(TourAnchors.settingsAccentRow),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              key: const ValueKey('settings-appearance'),
              leading: Icon(Icons.palette_outlined, color: ac.fgDim),
              title: Text('Appearance',
                  style: AymaType.sans(size: 15, color: ac.fg)),
              subtitle: Text('Theme and accent colour',
                  style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
              trailing: Icon(Icons.chevron_right, color: ac.fgMute),
              onTap: () => context.push(AppearanceSettingsScreen.path),
            ),
          ),
          KeyedSubtree(
            key: TourAnchors.keyFor(TourAnchors.settingsNotificationsRow),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              key: const ValueKey('settings-notifications'),
              leading: Icon(Icons.notifications_outlined, color: ac.fgDim),
              title: Text('Notification preferences',
                  style: AymaType.sans(size: 15, color: ac.fg)),
              subtitle: Text('Choose what Ayma can notify you about.',
                  style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
              trailing: Icon(Icons.chevron_right, color: ac.fgMute),
              onTap: () => context.push(NotificationPrefsScreen.path),
            ),
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            key: const ValueKey('settings-privacy'),
            leading: Icon(Icons.privacy_tip_outlined, color: ac.fgDim),
            title: Text('Privacy',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text(
                'Pause matching, face checks, wipe and delete account',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(PrivacySettingsScreen.path),
          ),
          Divider(color: ac.lineSoft),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: Icon(Icons.record_voice_over_outlined, color: ac.fgDim),
            title: Text('Ayma’s models',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Pick her brain, voice & language',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(VoicePreferenceScreen.path),
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            key: const Key('ayma_settings_connect_agent'),
            leading: Icon(Icons.hub_outlined, color: ac.fgDim),
            title: Text('Connect an agent (MCP)',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Let your own AI agent use Ayma',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(ConnectAgentScreen.path),
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            key: const ValueKey('settings-feature-tour'),
            leading: Icon(Icons.explore_outlined, color: ac.fgDim),
            title: Text('How to use Ayma',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Have Ayma walk you through the app, live.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            // The guided tour is Ayma-driven (rewire, founder 2026-11-07):
            // route into the Ayma chat and seed the ask — she runs the live
            // tour herself, screen by screen. This tile no longer replays
            // the passive coach-mark tour (that content is help, not a tour).
            onTap: () {
              ChatInbox.instance.push(ChatKickoff.guidedTour());
              context.go(MainShellScreen.path);
            },
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
}
