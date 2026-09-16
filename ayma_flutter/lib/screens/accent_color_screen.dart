import 'package:flutter/material.dart';

import '../services/accent_color_controller.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_primitives.dart';

/// Accent Color settings (Task 4): drag across a hand-painted hue strip to
/// pick a single colour; every frame of the drag live-updates the running
/// app's accent everywhere (`AccentColorController.preview`) and this
/// screen's own orb/button/nav-bar previews, and releasing persists the pick
/// as the new default (`AccentColorController.set`).
///
/// A hue strip rather than a full wheel/palette, per this app's own
/// established preference for small hand-built `CustomPainter` UI over a
/// third-party picker package — full saturation and a fixed 50% lightness
/// keep every pick as vivid as the Cherry Fuchsia default rather than
/// drifting into muddy/pastel territory.
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

  late double _hue = HSLColor.fromColor(_accent.color).hue;

  Color get _selected => HSLColor.fromAHSL(1, _hue, 1, 0.5).toColor();

  void _onDrag(BuildContext context, Offset localPosition, double width) {
    final t = (localPosition.dx / width).clamp(0.0, 1.0);
    final hue = t * 360;
    if (hue == _hue) return;
    setState(() => _hue = hue);
    _accent.preview(_selected);
  }

  void _commit() => _accent.set(_selected);

  void _reset() {
    setState(() => _hue = HSLColor.fromColor(AymaColors.accent).hue);
    _accent.resetToDefault();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Accent Color')),
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
          const SizedBox(height: 32),
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
                    painter: _HueStripPainter(hue: _hue),
                  ),
                ),
              );
            },
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
              label: const Text('Reset to Cherry Fuchsia'),
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
  _HueStripPainter({required this.hue});

  final double hue;

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
        ..shader = LinearGradient(colors: colors).createShader(Offset.zero & size),
    );

    final handleX = (hue / 360) * size.width;
    final handleCenter = Offset(handleX.clamp(size.height / 2,
        size.width - size.height / 2), size.height / 2);
    final selected = HSLColor.fromAHSL(1, hue, 1, 0.5).toColor();

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
  bool shouldRepaint(_HueStripPainter old) => old.hue != hue;
}
