import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../build_info.dart';
import '../services/api_client.dart';
import '../services/profile_service.dart';
import '../services/theme_controller.dart';
import '../theme.dart';
import 'release_notes_screen.dart';

/// App settings (§14.3): appearance (§14.1), pause matching (§14.2), and the
/// wiki reset (§14.2). Deletion / sign out / voice / notifications live on
/// their own screens reached from the Profile tab.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    ThemeController? controller,
    this.profileService,
    this.api,
  }) : _controller = controller;

  static const path = '/settings';

  final ThemeController? _controller;
  final ProfileService? profileService;
  final ApiClient? api;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ThemeController get _theme => widget._controller ?? themeControllerGlobal;
  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();
  late final ApiClient _api = widget.api ?? ApiClient();

  bool _resetting = false;

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Ayma’s memory of you has been cleared.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not reset ($e).')));
      }
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Appearance',
                style: AymaType.mono(size: 11, color: ac.fgMute)),
          ),
          AnimatedBuilder(
            animation: _theme,
            builder: (context, _) => Column(
              children: [
                for (final mode in ThemeMode.values)
                  RadioListTile<ThemeMode>(
                    value: mode,
                    groupValue: _theme.mode,
                    onChanged: (m) => _theme.set(m!),
                    title: Text(_label(mode),
                        style: AymaType.sans(size: 15, color: ac.fg)),
                  ),
              ],
            ),
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
          ListTile(
            title: Text('Wipe what Ayma has learned',
                style: AymaType.sans(size: 15, color: AymaColors.error)),
            subtitle: Text('Clears your wiki + history; keeps your account.',
                style:
                    AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: _resetting
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _resetting ? null : _confirmReset,
          ),
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
