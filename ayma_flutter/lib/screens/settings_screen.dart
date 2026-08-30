import 'package:flutter/material.dart';

import '../services/theme_controller.dart';
import '../theme.dart';

/// App settings (§14.3). Currently the appearance toggle (§14.1, Step 62);
/// other settings live on their own screens reached from the Profile tab.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, ThemeController? controller})
      : _controller = controller;

  static const path = '/settings';

  final ThemeController? _controller;
  ThemeController get themeController => _controller ?? themeControllerGlobal;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AnimatedBuilder(
        animation: themeController,
        builder: (context, _) => ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Appearance',
                  style: AymaType.mono(size: 11, color: ac.fgMute)),
            ),
            for (final mode in ThemeMode.values)
              RadioListTile<ThemeMode>(
                value: mode,
                groupValue: themeController.mode,
                onChanged: (m) => themeController.set(m!),
                title: Text(_label(mode),
                    style: AymaType.sans(size: 15, color: ac.fg)),
              ),
          ],
        ),
      ),
    );
  }

  static String _label(ThemeMode m) => switch (m) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'Match system',
      };
}
