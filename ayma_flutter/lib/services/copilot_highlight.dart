import 'dart:math' as math;

/// Pure coordinate math + wire models for the screen co-pilot.
///
/// The backend vision pass returns a target in *normalized* coordinates
/// (fractions of the shared frame). The Android overlay window spans the
/// full display (FLAG_LAYOUT_IN_SCREEN, status bar included), so drawing
/// the ring is a mapping problem: normalized frame space → display pixels,
/// across three real-world wrinkles:
///
///  * the frame may have been captured in a different orientation than the
///    display is in now (the user rotated the phone between the last frame
///    and the ask) — handled with quarter-turn rotation;
///  * a capture source that excludes the status bar would offset every y by
///    that bar's height — MediaProjection captures the FULL display, but
///    the mapper takes the flag so the math is explicit and tested;
///  * model output can be sloppy — every mapped rect is clamped on-screen
///    with a minimum tappable size.
///
/// This file has no platform imports so it is fully unit-testable
/// (test/copilot_highlight_test.dart).

/// What kind of element the vision pass found.
enum CopilotTargetKind { button, textField, link, tab, other }

CopilotTargetKind copilotKindFromWire(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'text_field':
    case 'textfield':
      return CopilotTargetKind.textField;
    case 'button':
      return CopilotTargetKind.button;
    case 'link':
      return CopilotTargetKind.link;
    case 'tab':
      return CopilotTargetKind.tab;
    default:
      return CopilotTargetKind.other;
  }
}

/// One locate result from `POST /copilot/locate`.
class CopilotTarget {
  const CopilotTarget({
    required this.found,
    this.x = 0,
    this.y = 0,
    this.w = 0,
    this.h = 0,
    this.label = '',
    this.kind = CopilotTargetKind.other,
    this.confidence = 0,
    this.draftText,
    this.draftSay = '',
    this.copyRequiresConfirmation = false,
    this.say = '',
  });

  final bool found;

  /// Normalized center (0..1 of frame width/height) and size (0..1).
  final double x;
  final double y;
  final double w;
  final double h;

  final String label;
  final CopilotTargetKind kind;
  final double confidence;

  /// For a text-field target: the text Ayma drafted for the user to review
  /// and paste. Never auto-inserted anywhere — the app puts it on the
  /// clipboard only after the user taps Copy.
  final String? draftText;

  /// The voice-flow readback for [draftText], built deterministically
  /// server-side: Ayma reads the draft aloud and asks before copying.
  /// Empty when there is no draft.
  final String draftSay;

  /// True when a draft is present: the clipboard write is gated on the
  /// user's explicit confirmation — tapping "Copy Ayma's draft", or a
  /// spoken yes in a voice walkthrough (Ayma then taps that same button
  /// via ui_action). A locate result alone never copies anything.
  final bool copyRequiresConfirmation;

  /// What Ayma says aloud about the draft in a voice walkthrough: the
  /// server-built [draftSay], or the same shape built locally when an
  /// older backend did not send one. Empty when there is no draft.
  String get voiceDraftPrompt {
    if (draftSay.isNotEmpty) return draftSay;
    final draft = draftText;
    if (draft == null) return '';
    return "I drafted this: '$draft' "
        'Want me to copy it so you can paste it?';
  }

  /// One spoken-style sentence naming the element and what tapping does.
  final String say;

  factory CopilotTarget.fromJson(Map<String, dynamic> json) {
    double numOf(String key) {
      final v = json[key];
      return v is num ? v.toDouble() : 0;
    }

    final draft = (json['draft_text'] as String?)?.trim();
    return CopilotTarget(
      found: json['found'] == true,
      x: numOf('x'),
      y: numOf('y'),
      w: numOf('w'),
      h: numOf('h'),
      label: (json['label'] as String? ?? '').trim(),
      kind: copilotKindFromWire(json['kind'] as String?),
      confidence: numOf('confidence'),
      draftText: (draft == null || draft.isEmpty) ? null : draft,
      draftSay: (json['draft_say'] as String? ?? '').trim(),
      copyRequiresConfirmation: json['copy_requires_confirmation'] == true,
      say: (json['say'] as String? ?? '').trim(),
    );
  }
}

/// The geometry a mapping runs against.
///
/// [displayWidthPx]/[displayHeightPx] are the FULL display (the overlay's
/// coordinate space). [frameWidthPx]/[frameHeightPx] are the captured
/// frame's own size — for MediaProjection the full display at capture time,
/// so the two pairs differ exactly when the device rotated after capture.
/// [quarterTurns] is how many clockwise quarter turns the frame needs to
/// match the display's current orientation (0 when they already agree).
class CopilotGeometry {
  const CopilotGeometry({
    required this.displayWidthPx,
    required this.displayHeightPx,
    required this.frameWidthPx,
    required this.frameHeightPx,
    this.statusBarHeightPx = 0,
    this.frameIncludesStatusBar = true,
    this.quarterTurns = 0,
  });

  final double displayWidthPx;
  final double displayHeightPx;
  final double frameWidthPx;
  final double frameHeightPx;
  final double statusBarHeightPx;
  final bool frameIncludesStatusBar;
  final int quarterTurns;

  /// Quarter turns implied purely by the two aspect orientations: when the
  /// frame is landscape but the display is portrait (or vice versa) the
  /// frame needs one turn (direction is ambiguous from size alone; the
  /// native side reports the display rotation, and this fallback assumes
  /// the common clockwise case).
  static int impliedQuarterTurns({
    required double frameWidthPx,
    required double frameHeightPx,
    required double displayWidthPx,
    required double displayHeightPx,
  }) {
    final frameLandscape = frameWidthPx > frameHeightPx;
    final displayLandscape = displayWidthPx > displayHeightPx;
    return frameLandscape == displayLandscape ? 0 : 1;
  }
}

/// A rect in overlay/display pixels, ready to hand to the native overlay.
class OverlayRect {
  const OverlayRect({
    required this.centerX,
    required this.centerY,
    required this.width,
    required this.height,
  });

  final double centerX;
  final double centerY;
  final double width;
  final double height;

  @override
  String toString() =>
      'OverlayRect(center: $centerX,$centerY size: ${width}x$height)';
}

/// Maps normalized frame coordinates to overlay display pixels.
abstract final class CopilotCoordinateMapper {
  /// The smallest ring we will draw (a fingertip target); smaller model
  /// sizes are grown to this so the ring stays visible and meaningful.
  static const double minTargetPx = 44;

  static double _clamp01(double v) =>
      v.isNaN ? 0 : math.min(1, math.max(0, v));

  /// Rotate a normalized point by [quarterTurns] clockwise quarter turns.
  static (double, double) rotateNormalized(double x, double y, int turns) {
    var nx = _clamp01(x);
    var ny = _clamp01(y);
    final t = ((turns % 4) + 4) % 4;
    for (var i = 0; i < t; i++) {
      final px = nx;
      final py = ny;
      nx = 1 - py;
      ny = px;
    }
    return (nx, ny);
  }

  /// Map one target through [geometry] into overlay pixels.
  static OverlayRect mapTarget(CopilotTarget target, CopilotGeometry geometry) {
    final turns = geometry.quarterTurns;
    final (nx, ny) = rotateNormalized(target.x, target.y, turns);
    // Odd turns swap the axes, so the size fractions swap too.
    final nw = turns.isOdd ? _clamp01(target.h) : _clamp01(target.w);
    final nh = turns.isOdd ? _clamp01(target.w) : _clamp01(target.h);

    final dw = geometry.displayWidthPx;
    final dh = geometry.displayHeightPx;

    double centerX = nx * dw;
    double centerY;
    double widthPx = nw * dw;
    double heightPx;
    if (geometry.frameIncludesStatusBar) {
      centerY = ny * dh;
      heightPx = nh * dh;
    } else {
      // The frame starts below the status bar: shift y into display space
      // and scale heights against the frame's own region of the display.
      final regionHeight = math.max(1, dh - geometry.statusBarHeightPx);
      centerY = geometry.statusBarHeightPx + ny * regionHeight;
      heightPx = nh * regionHeight;
    }

    widthPx = math.max(minTargetPx, widthPx);
    heightPx = math.max(minTargetPx, heightPx);
    // Keep the whole ring on screen (the native side adds its own halo pad).
    centerX = math.min(
      dw - widthPx / 2,
      math.max(widthPx / 2, centerX),
    );
    centerY = math.min(
      dh - heightPx / 2,
      math.max(heightPx / 2, centerY),
    );
    return OverlayRect(
      centerX: centerX,
      centerY: centerY,
      width: widthPx,
      height: heightPx,
    );
  }

  /// Convert a pixel position inside the captured frame (e.g. a point the
  /// model reports in frame pixels) into overlay display pixels. Unlike
  /// [mapTarget] this applies no minimum-ring growth: a point maps to a
  /// point, clamped only to the display edges.
  static (double, double) framePixelToOverlay(
    double frameX,
    double frameY,
    CopilotGeometry geometry,
  ) {
    final fw = math.max(1, geometry.frameWidthPx);
    final fh = math.max(1, geometry.frameHeightPx);
    final (nx, ny) = rotateNormalized(
      frameX / fw,
      frameY / fh,
      geometry.quarterTurns,
    );
    final dw = geometry.displayWidthPx;
    final dh = geometry.displayHeightPx;
    final x = math.min(dw, math.max(0.0, nx * dw));
    final double y;
    if (geometry.frameIncludesStatusBar) {
      y = math.min(dh, math.max(0.0, ny * dh));
    } else {
      final regionHeight = math.max(1, dh - geometry.statusBarHeightPx);
      y = math.min(
        dh,
        math.max(0.0, geometry.statusBarHeightPx + ny * regionHeight),
      );
    }
    return (x, y);
  }
}

/// Mirrors the native black-frame threshold
/// (CopilotProjectionService.BLACK_LUMINANCE_MAX): at or below this sampled
/// mean luminance a frame is a FLAG_SECURE black frame and must be treated
/// as "Ayma cannot see this screen" — never uploaded, never located on.
const double kCopilotBlackLuminanceMax = 4.0;

bool copilotIsBlackFrame(double meanLuminance) =>
    meanLuminance <= kCopilotBlackLuminanceMax;
