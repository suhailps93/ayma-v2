import 'package:flutter/material.dart';

import '../services/accent_color_controller.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/ayma_back_button.dart';

/// Live accent controls with hue, saturation, brightness and neutral shortcuts.
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
  double get _hue => _color.hue;

  Color get _selected => _color.toColor();

  void _onDrag(BuildContext context, Offset localPosition, double width) {
    final t = (localPosition.dx / width).clamp(0.0, 1.0);
    final hue = t * 360;
    if (hue == _hue) return;
    setState(() => _color = _color.withHue(hue));
    _accent.preview(_selected);
  }

  void _commit() => _accent.set(_selected);

  void _reset() {
    setState(() => _color = HSVColor.fromColor(AymaColors.accent));
    _accent.resetToDefault();
  }

  void _adjust(HSVColor color) {
    setState(() => _color = color);
    _accent.preview(_selected);
  }

  void _neutral(double brightness) {
    _adjust(_color.withSaturation(0).withValue(brightness));
    _commit();
  }

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
            'Drag to pick a colour — it applies everywhere Ayma shows '
            'accent, live, and stays your default.',
            style: AymaType.sans(size: 13, soft: true, color: ac.fgDim),
          ),
          const SizedBox(height: 28),
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
                onPanEnd: (_) => _commit(),
                onPanCancel: _commit,
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
            inactiveColor: ac.lineSoft,
            value: _color.saturation,
            label: '${(_color.saturation * 100).round()}%',
            onChanged: (v) => _adjust(_color.withSaturation(v)),
            onChangeEnd: (_) => _commit(),
          ),
          Text('Brightness', style: AymaType.sans(color: ac.fg)),
          Slider(
            key: const Key('accentBrightness'),
            activeColor: ac.fg,
            inactiveColor: ac.lineSoft,
            value: _color.value,
            label: '${(_color.value * 100).round()}%',
            onChanged: (v) => _adjust(_color.withValue(v)),
            onChangeEnd: (_) => _commit(),
          ),
          Wrap(
            spacing: 12,
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
          const SizedBox(height: 28),
          DividerLabel('preview'),
          const SizedBox(height: 4),
          AnimatedBuilder(
            animation: _accent,
            builder: (context, _) => Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () {},
                    child: const Text('Sample button'),
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
              onPressed: _reset,
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
