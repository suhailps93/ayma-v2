import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/accent_color_controller.dart';
import '../services/theme_controller.dart';
import '../services/tour_request.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/ayma_toast.dart';
import 'camera_color_picker_screen.dart';
import 'main_shell_screen.dart';

/// Appearance (§14.1): theme mode and accent colour, grouped under the
/// single Appearance row on Settings (founder cleanup, 2026-11-07 — the
/// Settings top level carries only four section rows plus the two plain
/// Ayma line items).
///
/// Accent colour (founder, build 2491): this is the ONE and ONLY accent
/// surface — the standalone Accent Color page is gone. The preset swatches,
/// the full custom picker (hue strip, saturation, brightness, live orb
/// preview) and the camera/eyedropper sampling entry all live inline here.
///
/// Realtime model (Nov 17, carried over verbatim from the old standalone
/// screen + [AccentColorController]): every pick — a preset tap, a hue drag,
/// a slider, a neutral chip, a colour sampled from the camera — is a live
/// **preview** only. The whole app re-themes in real time, but nothing is
/// saved. "Use this color" is the SOLE persist (`_accent.set`). Leaving this
/// page without pressing it reverts the app to the previously-saved accent
/// and writes nothing (`dispose` → `_accent.cancelPreview(_savedColor)`).
/// "Reset to default" previews the default without persisting.
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

  /// HSV of the current pick, backing the hue strip + saturation/brightness
  /// sliders so they always reflect the live preview.
  late HSVColor _color = HSVColor.fromColor(_accent.color);

  /// The exact current pick. Every interaction updates this; "Use this color"
  /// persists exactly this value (so a preset or sampled colour saves without
  /// HSV round-trip drift).
  late Color _pending = _accent.color;

  /// The accent to restore on a non-committed leave: the colour saved when the
  /// page opened, advanced to each committed pick. Live previews drift the
  /// controller away from this; [dispose] restores it unless the pick was
  /// committed (then it already equals the controller colour).
  late Color _savedColor;

  double get _hue => _color.hue;

  @override
  void initState() {
    super.initState();
    // Capture the saved baseline BEFORE any preview mutates the controller.
    _savedColor = _accent.color;
  }

  @override
  void dispose() {
    // Every exit path (back arrow, Android back, swipe, nav away) disposes this
    // State. Revert the live preview to the saved baseline WITHOUT persisting;
    // a committed pick already equals the baseline, so this is a no-op then.
    _accent.cancelPreview(_savedColor);
    super.dispose();
  }

  /// Live-preview an exact colour (preset swatch, Custom swatch, camera
  /// sample). Previews everywhere, persists nothing.
  void _previewColor(Color color) {
    setState(() {
      _color = HSVColor.fromColor(color);
      _pending = color;
    });
    _accent.preview(color);
  }

  /// Live-preview from an HSV adjustment (hue strip, sliders, neutral chips).
  void _adjust(HSVColor color) {
    setState(() {
      _color = color;
      _pending = color.toColor();
    });
    _accent.preview(_pending);
  }

  void _onHueDrag(Offset localPosition, double width) {
    final t = (localPosition.dx / width).clamp(0.0, 1.0);
    final hue = t * 360;
    if (hue == _hue) return;
    _adjust(_color.withHue(hue));
  }

  void _neutral(double brightness) =>
      _adjust(_color.withSaturation(0).withValue(brightness));

  /// The ONLY persist path: saves the previewed pick (local + Firestore
  /// best-effort) and advances the revert baseline so leaving keeps it. A
  /// non-preset pick is also stored as the Custom swatch.
  Future<void> _useThisColor() async {
    final saved = _pending;
    await _accent.set(saved);
    final isPreset =
        accentPresets.any((p) => p.color.toARGB32() == saved.toARGB32());
    if (!isPreset) await _accent.saveCustomColor(saved);
    _savedColor = saved;
    if (!mounted) return;
    AymaToast.show(context, 'Accent colour saved',
        kind: AymaToastKind.success);
  }

  /// Preview the default accent (no persist — only "Use this color" saves).
  void _resetPreview() => _previewColor(AymaColors.accent);

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
          leading: const AymaBackButton(), title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
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
          Divider(color: ac.lineSoft),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text('Accent Color',
                style: AymaType.sans(size: 15, color: ac.fg)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              'Cherry Fuchsia by default. Pick a preset or dial in your own — '
              'the app previews it live. Tap "Use this color" to save it; '
              'leave without saving and your previous colour comes back.',
              style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
            ),
          ),
          _accentSwatches(ac),
          const SizedBox(height: 8),
          Center(
            child: AnimatedBuilder(
              animation: _accent,
              builder: (context, _) => const AymaOrb(
                size: 120,
                state: AymaOrbState.speaking,
                amplitude: 0.5,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return GestureDetector(
                  onPanStart: (d) => _onHueDrag(d.localPosition, width),
                  onPanUpdate: (d) => _onHueDrag(d.localPosition, width),
                  child: SizedBox(
                    height: 56,
                    width: double.infinity,
                    child: CustomPaint(
                      key: const Key('hueStrip'),
                      painter: _HueStripPainter(
                          hue: _hue, selected: _color.toColor()),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Saturation', style: AymaType.sans(color: ac.fg)),
                Slider(
                  key: const Key('accentSaturation'),
                  activeColor: ac.fg,
                  value: _color.saturation,
                  label: '${(_color.saturation * 100).round()}%',
                  onChanged: (v) => _adjust(_color.withSaturation(v)),
                ),
                Text('Brightness', style: AymaType.sans(color: ac.fg)),
                Slider(
                  key: const Key('accentBrightness'),
                  activeColor: ac.fg,
                  value: _color.value,
                  label: '${(_color.value * 100).round()}%',
                  onChanged: (v) => _adjust(_color.withValue(v)),
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    for (final entry in const {
                      'Black': 0.0,
                      'Gray': 0.5,
                      'White': 1.0,
                    }.entries)
                      ActionChip(
                        label: Text(entry.key),
                        onPressed: () => _neutral(entry.value),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Text contrast adjusts automatically for readability.',
                  style: AymaType.sans(size: 12, color: ac.fgDim),
                ),
                const SizedBox(height: 8),
                DividerLabel('preview'),
                const SizedBox(height: 8),
                AnimatedBuilder(
                  animation: _accent,
                  builder: (context, _) => Row(
                    children: [
                      // The real save action doubles as the live accent sample.
                      Expanded(
                        child: FilledButton(
                          key: const Key('useThisColor'),
                          onPressed: _useThisColor,
                          child: const Text('Use this color'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        width: 52,
                        height: 52,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: ac.accentSoft,
                          shape: BoxShape.circle,
                          border: Border.all(color: ac.accent, width: 1.5),
                        ),
                        child: const AymaOrb(
                            size: 26, state: AymaOrbState.listening),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Center(
                  child: OutlinedButton.icon(
                    onPressed: _resetPreview,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Reset to default'),
                  ),
                ),
              ],
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

  Widget _accentSwatches(AymaTokens ac) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
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
                  onTap: () => _previewColor(preset.color),
                  child: _buildSwatchCircle(
                    color: preset.color,
                    isSelected:
                        _accent.color.toARGB32() == preset.color.toARGB32(),
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
                  onTap: () => _previewColor(_accent.customColor!),
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
                  // Sampling an eyedropper colour from the camera hands it back
                  // as the current pick WITH live preview — it does NOT save.
                  // "Use this color" remains the sole persist.
                  onTap: () async {
                    final picked = await context
                        .push<Color>(CameraColorPickerScreen.path);
                    if (picked != null) _previewColor(picked);
                  },
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: ac.bgElev,
                      shape: BoxShape.circle,
                      border: Border.all(color: ac.lineSoft, width: 1.5),
                    ),
                    child: Icon(Icons.camera_alt_outlined,
                        size: 20, color: ac.fg),
                  ),
                ),
              ),
            ),
          ],
        ),
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

/// Hand-painted full-hue strip (0-360°, fixed S=1/L=0.5) with a drag handle
/// showing the currently selected colour.
class _HueStripPainter extends CustomPainter {
  _HueStripPainter({required this.hue, required this.selected});

  final double hue;
  final Color selected;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );
    final colors = [
      for (var i = 0; i <= 12; i++)
        HSLColor.fromAHSL(1, i * 30.0, 1, 0.5).toColor(),
    ];
    canvas.drawRRect(
      track,
      Paint()
        ..shader = LinearGradient(colors: colors)
            .createShader(Offset.zero & size),
    );

    final handleX = (hue / 360) * size.width;
    final handleCenter = Offset(
      handleX.clamp(size.height / 2, size.width - size.height / 2),
      size.height / 2,
    );

    canvas.drawCircle(
      handleCenter,
      size.height / 2 + 3,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawCircle(
      handleCenter,
      size.height / 2 - 2,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      handleCenter,
      size.height / 2 - 6,
      Paint()..color = selected,
    );
  }

  @override
  bool shouldRepaint(_HueStripPainter old) =>
      old.hue != hue || old.selected != selected;
}
