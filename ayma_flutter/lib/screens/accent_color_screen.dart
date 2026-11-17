import 'package:flutter/material.dart';

import '../services/accent_color_controller.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/ayma_back_button.dart';

/// Live accent controls with hue, saturation, brightness and neutral shortcuts.
///
/// Founder model (Nov 17): every in-picker change is a live **preview** only —
/// the whole app re-themes in real time as the user drags, but nothing is
/// saved. "Use this color" is the ONLY action that persists the pick. Leaving
/// the screen without pressing it reverts the app to the previously-saved
/// accent and writes nothing.
class AccentColorScreen extends StatefulWidget {
  const AccentColorScreen({super.key, this.controller});

  static const path = '/settings/accent-color';

  final AccentColorController? controller;

  @override
  State<AccentColorScreen> createState() => _AccentColorScreenState();
}

class _AccentColorScreenState extends State<AccentColorScreen> {
  AccentColorController get _accent =>
      widget.controller ?? accentColorControllerGlobal;

  late HSVColor _color = HSVColor.fromColor(_accent.color);

  /// The accent to restore on a non-committed leave: the colour that was saved
  /// when the picker opened, advanced to each committed pick. On a live preview
  /// the controller drifts away from this; `dispose` restores it unless the
  /// pick was committed (then it already equals the controller colour).
  late Color _savedColor;

  double get _hue => _color.hue;

  Color get _selected => _color.toColor();

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

  void _onDrag(BuildContext context, Offset localPosition, double width) {
    final t = (localPosition.dx / width).clamp(0.0, 1.0);
    final hue = t * 360;
    if (hue == _hue) return;
    setState(() => _color = _color.withHue(hue));
    _accent.preview(_selected);
  }

  /// The ONLY persist path: saves the previewed pick (local + Firestore
  /// best-effort) and advances the revert baseline so leaving keeps it.
  Future<void> _useThisColor() async {
    final saved = _selected;
    await _accent.set(saved);
    _savedColor = saved;
    if (!mounted) return;
    AymaToast.show(context, 'Accent colour saved',
        kind: AymaToastKind.success);
    Navigator.of(context).maybePop();
  }

  /// Preview the default accent (no persist — only "Use this color" saves).
  void _resetPreview() {
    setState(() => _color = HSVColor.fromColor(AymaColors.accent));
    _accent.preview(AymaColors.accent);
  }

  void _adjust(HSVColor color) {
    setState(() => _color = color);
    _accent.preview(_selected);
  }

  void _neutral(double brightness) =>
      _adjust(_color.withSaturation(0).withValue(brightness));

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Accent Color')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            'Drag to preview a colour live everywhere Ayma shows accent. '
            'Tap "Use this color" to save it — leave without saving and your '
            'previous colour comes back.',
            style: AymaType.sans(size: 13, soft: true, color: ac.fgDim),
          ),
          const SizedBox(height: 24),
          Center(
            child: AnimatedBuilder(
              animation: _accent,
              builder: (context, _) => AymaOrb(
                size: 140,
                state: AymaOrbState.speaking,
                amplitude: 0.5,
              ),
            ),
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return GestureDetector(
                onPanStart: (d) => _onDrag(context, d.localPosition, width),
                onPanUpdate: (d) => _onDrag(context, d.localPosition, width),
                child: SizedBox(
                  height: 56,
                  width: double.infinity,
                  child: CustomPaint(
                    key: const Key('hueStrip'),
                    painter: _HueStripPainter(hue: _hue, selected: _selected),
                  ),
                ),
              );
            },
          ),

          const SizedBox(height: 20),
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
                  child: AymaOrb(size: 26, state: AymaOrbState.listening),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Center(
            child: OutlinedButton.icon(
              onPressed: _resetPreview,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Reset to default'),
            ),
          ),
        ],
      ),
    );
  }
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
        ..shader = LinearGradient(
          colors: colors,
        ).createShader(Offset.zero & size),
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
