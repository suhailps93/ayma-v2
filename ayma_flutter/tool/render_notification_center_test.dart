import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:ayma_flutter/widgets/ayma_rail_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline verification renderer for the notification-centre redesign
/// (2026-09-22, founder reference screenshot) — not part of the regular
/// test suite (lives under tool/, which `flutter test` doesn't scan by
/// default), same pattern as `generate_rail_icons_test.dart` and
/// `render_orb_verification_test.dart`. Run explicitly:
///   flutter test tool/render_notification_center_test.dart
///
/// Deliberately a pure-canvas render (glyph/orb `CustomPainter`s + raw
/// `TextPainter`s), not a mounted `NotificationCenterScreen` widget tree —
/// mounting the real screen (`StreamBuilder` + a live `AymaOrb`, whose
/// `AnimationController.repeat()` never stops ticking) hung this offline
/// renderer indefinitely even with bounded `pump()` calls instead of
/// `pumpAndSettle()`, so this renders each row exactly the way
/// `_EntryRow`/`_Leading`/`_SectionHeader` in `notification_center_screen.dart`
/// compose it (same styles, same icon-circle geometry, same
/// `AymaOrbPainter` call `render_orb_verification_test.dart` already proved
/// safe to call directly), just without a widget tree or a ticking
/// controller.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render the notification centre for visual verification', () async {
    const accent = AymaColors.accent; // Cherry Fuchsia default.
    const bg = AymaColors.darkBg;
    const bgCard = AymaColors.darkBgCard;
    const fg = AymaColors.darkFg;
    const fgDim = AymaColors.darkFgDim;
    const fgMute = AymaColors.darkFgMute;
    const lineSoft = AymaColors.darkLineSoft;

    const width = 480.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // Background painted up front; final height is only known once every
    // row has been laid out below, so the whole picture is re-recorded at
    // the end into a canvas of the right size (cheap: this is a one-shot
    // offline tool, not a hot path).
    final rows = <_RowSpec>[
      _RowSpec.header('TODAY'),
      _RowSpec(
        icon: _IconKind.match,
        title: 'I found someone. Marco, 34.',
        subtitle: 'Deep dive & match results',
        time: '6:42 PM',
      ),
      _RowSpec(
        icon: _IconKind.checkin,
        title: 'Ready for a 10-minute check-in?',
        subtitle: null,
        time: '4:10 PM',
        italicSerif: true,
      ),
      _RowSpec(
        icon: _IconKind.heart,
        title: 'You and Jamie liked each other.',
        subtitle: 'New matches',
        time: '2:42 PM',
      ),
      _RowSpec.header('YESTERDAY'),
      _RowSpec(
        icon: _IconKind.search,
        title: 'Your deep dive on yourself is ready.',
        subtitle: 'Deep dive & match results',
        time: '9:20 PM',
      ),
      _RowSpec(
        icon: _IconKind.chat,
        title: 'Theo',
        subtitle: "Hey — no templates, just me.",
        time: '5:55 PM',
      ),
    ];

    double y = 12;
    final ops = <void Function(Canvas)>[];
    for (final row in rows) {
      if (row.isHeader) {
        y = _layoutHeader(ops, row.title, y, width, fgMute, lineSoft);
      } else {
        y = _layoutRow(ops, row, y, width,
            accent: accent,
            bgCard: bgCard,
            fg: fg,
            fgDim: fgDim,
            fgMute: fgMute,
            lineSoft: lineSoft);
      }
    }
    final height = y + 12;

    canvas.drawRect(
        Rect.fromLTWH(0, 0, width, height), Paint()..color = bg);
    for (final op in ops) {
      op(canvas);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width.round(), height.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull);

    final file = File('build/notification_center_preview.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote ${file.path} (${bytes.lengthInBytes} bytes)');
  });
}

enum _IconKind { heart, match, search, chat, checkin }

class _RowSpec {
  _RowSpec({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.time,
    this.italicSerif = false,
  }) : isHeader = false;

  _RowSpec.header(this.title)
      : isHeader = true,
        icon = _IconKind.heart,
        subtitle = null,
        time = '',
        italicSerif = false;

  final bool isHeader;
  final _IconKind icon;
  final String title;
  final String? subtitle;
  final String time;
  final bool italicSerif;
}

TextPainter _tp(String text, TextStyle style,
    {double maxWidth = double.infinity, int maxLines = 100}) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: maxLines < 100 ? '…' : null,
  )..layout(maxWidth: maxWidth);
  return tp;
}

const _pad = 16.0;
const _iconSize = 40.0;
const _gap = 12.0;

double _layoutHeader(List<void Function(Canvas)> ops, String label, double y,
    double width, Color fgMute, Color lineSoft) {
  final top = y + (y == 12 ? 0 : 10);
  final labelStyle =
      AymaType.mono(size: 11, color: fgMute).copyWith(letterSpacing: 2.4);
  final tp = _tp(label, labelStyle);
  final textY = top;
  ops.add((c) => tp.paint(c, Offset(_pad, textY)));
  final ruleY = textY + tp.height + 10;
  ops.add((c) => c.drawLine(Offset(_pad, ruleY), Offset(width - _pad, ruleY),
      Paint()..color = lineSoft));
  return ruleY + 1;
}

double _layoutRow(
  List<void Function(Canvas)> ops,
  _RowSpec row,
  double y,
  double width, {
  required Color accent,
  required Color bgCard,
  required Color fg,
  required Color fgDim,
  required Color fgMute,
  required Color lineSoft,
}) {
  final top = y + 14;
  final iconCenter = Offset(_pad + _iconSize / 2, top + _iconSize / 2);
  final textLeft = _pad + _iconSize + _gap;
  final textWidth = width - textLeft - _pad;

  // Icon circle backdrop (skipped for the check-in orb — its own gradient
  // sphere IS the icon, per the founder's reference).
  if (row.icon != _IconKind.checkin) {
    ops.add((c) => c.drawCircle(
        iconCenter, _iconSize / 2, Paint()..color = bgCard));
  }
  ops.add((c) {
    c.save();
    switch (row.icon) {
      case _IconKind.heart:
        c.translate(iconCenter.dx - 9, iconCenter.dy - 9);
        AymaHeartGlyph(accent: accent, filled: true, size: 18)
            .buildPainter()
            .paint(c, const Size(18, 18));
        break;
      case _IconKind.match:
        c.translate(iconCenter.dx - 9, iconCenter.dy - 9);
        AymaMatchGlyph(accent: accent, filled: true, size: 18)
            .buildPainter()
            .paint(c, const Size(18, 18));
        break;
      case _IconKind.search:
        c.translate(iconCenter.dx - 9, iconCenter.dy - 9);
        AymaSearchGlyph(accent: accent, filled: true, size: 18)
            .buildPainter()
            .paint(c, const Size(18, 18));
        break;
      case _IconKind.chat:
        c.translate(iconCenter.dx - 9, iconCenter.dy - 9);
        AymaChatGlyph(accent: accent, filled: true, size: 18)
            .buildPainter()
            .paint(c, const Size(18, 18));
        break;
      case _IconKind.checkin:
        // Same call `render_orb_verification_test.dart` already proved
        // safe offline — a direct painter call, no widget/ticker involved.
        c.translate(
            iconCenter.dx - _iconSize / 2, iconCenter.dy - _iconSize / 2);
        AymaOrbPainter(
          t: 185,
          fromState: AymaOrbState.idle,
          toState: AymaOrbState.idle,
          transitionT: 1,
          amplitude: 0,
          accent: accent,
          reducedMotion: false,
          showGlow: false,
        ).paint(c, const Size(_iconSize, _iconSize));
        break;
    }
    c.restore();
  });

  final titleStyle = row.italicSerif
      ? AymaType.serif(size: 17, italic: true, color: fg)
      : AymaType.sans(size: 14, color: fg, weight: FontWeight.w600);
  final timeStyle = AymaType.mono(size: 11, color: fgMute);
  final timeTp = row.time.isEmpty
      ? null
      : _tp(row.time, timeStyle);
  final titleMaxWidth =
      textWidth - (timeTp == null ? 0 : timeTp.width + 8);
  final titleTp = _tp(row.title, titleStyle,
      maxWidth: titleMaxWidth < 0 ? 0 : titleMaxWidth, maxLines: 2);

  final titleY = top;
  ops.add((c) => titleTp.paint(c, Offset(textLeft, titleY)));
  if (timeTp != null) {
    ops.add((c) => timeTp.paint(
        c, Offset(width - _pad - timeTp.width, titleY + 2)));
  }

  var nextY = titleY + titleTp.height;
  if (row.subtitle != null && row.subtitle!.isNotEmpty) {
    final subtitleStyle =
        AymaType.sans(size: 13, soft: true, color: fgMute);
    final subTp = _tp(row.subtitle!, subtitleStyle,
        maxWidth: textWidth, maxLines: 2);
    final subY = nextY + 3;
    ops.add((c) => subTp.paint(c, Offset(textLeft, subY)));
    nextY = subY + subTp.height;
  }

  final rowBottom =
      (nextY + 14).clamp(top - 14 + _iconSize + 14, double.infinity);
  ops.add((c) => c.drawLine(Offset(0, rowBottom), Offset(width, rowBottom),
      Paint()..color = lineSoft));
  return rowBottom;
}
