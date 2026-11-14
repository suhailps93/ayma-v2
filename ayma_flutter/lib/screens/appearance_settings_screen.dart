import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/accent_color_controller.dart';
import '../services/theme_controller.dart';
import '../services/tour_request.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import 'accent_color_screen.dart';
import 'camera_color_picker_screen.dart';
import 'main_shell_screen.dart';

/// Appearance (§14.1): theme mode and accent colour, grouped under the
/// single Appearance row on Settings (founder cleanup, 2026-11-07 — the
/// Settings top level carries only four section rows plus the two plain
/// Ayma line items). The feature-tour replay lives here too: it is a
/// walkthrough of the app's interface, and the Plan page stays exactly
/// as it was, so this is its closest home.
class AppearanceSettingsScreen extends StatefulWidget {
  const AppearanceSettingsScreen({
    super.key,
    this.controller,
    this.accentController,
  });

  static const path = '/settings/appearance';

  final ThemeController? controller;
  final AccentColorController? accentController;

  @override
  State<AppearanceSettingsScreen> createState() =>
      _AppearanceSettingsScreenState();
}

class _AppearanceSettingsScreenState extends State<AppearanceSettingsScreen> {
  ThemeController get _theme => widget.controller ?? themeControllerGlobal;
  AccentColorController get _accent =>
      widget.accentController ?? accentColorControllerGlobal;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
          leading: const AymaBackButton(), title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 20),
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
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                      horizontalTitleGap: 0,
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
            leading: Icon(Icons.palette_outlined, color: ac.fgDim),
            title: Text('Accent Color',
                style: AymaType.sans(size: 15, color: ac.fg)),
            subtitle: Text('Cherry Fuchsia by default — pick your own.',
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute)),
            trailing: Icon(Icons.chevron_right, color: ac.fgMute),
            onTap: () => context.push(AccentColorScreen.path),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            child: AnimatedBuilder(
              animation: _accent,
              builder: (context, _) => Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final preset in accentPresets)
                    Semantics(
                      button: true,
                      label: preset.label,
                      child: GestureDetector(
                        key: Key('accentPreset_${preset.key}'),
                        onTap: () => _accent.set(preset.color),
                        child: _buildSwatchCircle(
                          color: preset.color,
                          isSelected: _accent.color.toARGB32() ==
                              preset.color.toARGB32(),
                          label: preset.label,
                          ac: ac,
                        ),
                      ),
                    ),
                  if (_accent.customColor != null)
                    Semantics(
                      button: true,
                      label: 'Custom',
                      child: GestureDetector(
                        key: const Key('accentPreset_custom'),
                        onTap: () => _accent.set(_accent.customColor!),
                        child: _buildSwatchCircle(
                          color: _accent.customColor!,
                          isSelected: _accent.color.toARGB32() ==
                              _accent.customColor!.toARGB32(),
                          label: 'Custom',
                          ac: ac,
                          isCustom: true,
                        ),
                      ),
                    ),
                  Semantics(
                    button: true,
                    label: 'Pick from camera',
                    child: Tooltip(
                      message: 'Pick from camera',
                      child: GestureDetector(
                        key: const Key('pickFromCamera'),
                        onTap: () async {
                          final picked = await context
                              .push<Color>(CameraColorPickerScreen.path);
                          if (picked != null) {
                            await _accent.set(picked);
                            await _accent.saveCustomColor(picked);
                          }
                        },
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: ac.bgElev,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: ac.lineSoft,
                              width: 1.5,
                            ),
                          ),
                          child: Icon(
                            Icons.camera_alt_outlined,
                            size: 20,
                            color: ac.fg,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
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

  Widget _buildSwatchCircle({
    required Color color,
    required bool isSelected,
    required String label,
    required AymaTokens ac,
    bool isCustom = false,
  }) {
    return Tooltip(
      message: label,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? ac.fg : ac.lineSoft,
                width: isSelected ? 2.5 : 1.5,
              ),
            ),
            child: isCustom
                ? Center(
                    child: Icon(
                      Icons.colorize,
                      size: 16,
                      color: color.computeLuminance() > 0.5
                          ? Colors.black
                          : Colors.white,
                    ),
                  )
                : null,
          ),
          if (isSelected)
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
                shape: BoxShape.circle,
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
