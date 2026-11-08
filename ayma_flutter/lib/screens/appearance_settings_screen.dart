import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/theme_controller.dart';
import '../services/tour_request.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import 'accent_color_screen.dart';
import 'main_shell_screen.dart';

/// Appearance (§14.1): theme mode and accent colour, grouped under the
/// single Appearance row on Settings (founder cleanup, 2026-11-07 — the
/// Settings top level carries only four section rows plus the two plain
/// Ayma line items). The feature-tour replay lives here too: it is a
/// walkthrough of the app's interface, and the Plan page stays exactly
/// as it was, so this is its closest home.
class AppearanceSettingsScreen extends StatefulWidget {
  const AppearanceSettingsScreen({super.key, this._controller});

  static const path = '/settings/appearance';

  final ThemeController? _controller;

  @override
  State<AppearanceSettingsScreen> createState() =>
      _AppearanceSettingsScreenState();
}

class _AppearanceSettingsScreenState extends State<AppearanceSettingsScreen> {
  ThemeController get _theme => widget._controller ?? themeControllerGlobal;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
          leading: const AymaBackButton(), title: const Text('Appearance')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: _theme,
            builder: (context, _) => RadioGroup<ThemeMode>(
              groupValue: _theme.mode,
              onChanged: (m) => _theme.set(m!),
              child: Column(
                children: [
                  for (final mode in ThemeMode.values)
                    RadioListTile<ThemeMode>(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 20),
                      value: mode,
                      title: Text(_label(mode),
                          style: AymaType.sans(size: 15, color: ac.fg)),
                    ),
                ],
              ),
            ),
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: Icon(Icons.palette_outlined, color: ac.accent),
            title: Text('Accent Color',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Cherry Fuchsia by default — pick your own.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(AccentColorScreen.path),
          ),
          Divider(color: ac.lineSoft),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
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
