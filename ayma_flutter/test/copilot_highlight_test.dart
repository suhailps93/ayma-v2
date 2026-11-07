import 'package:ayma_flutter/services/copilot_highlight.dart';
import 'package:ayma_flutter/services/screen_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('voice Ayma may operate the copy button once the user says yes',
      () {
    // The confirmation relay for the voice flow: the "Copy Ayma's draft"
    // button must NOT be on the ui_action denylist (it is not a delete,
    // purchase, or consent control), so Ayma can tap it via ui_action
    // after the user confirms out loud — and only then.
    expect(
      uiDenial(
        label: "Copy Ayma's draft",
        type: 'button',
        route: '/copilot',
      ),
      isNull,
    );
  });

  group('copilotInstallIsSideloaded', () {
    test('Play installs are not sideloaded; everything else is', () {
      expect(copilotInstallIsSideloaded('com.android.vending'), isFalse);
      expect(copilotInstallIsSideloaded('com.android.chrome'), isTrue);
      expect(copilotInstallIsSideloaded('com.google.android.packageinstaller'),
          isTrue);
      // adb / unknown installer reads as sideloaded — those installs hit
      // the Restricted Settings lock too.
      expect(copilotInstallIsSideloaded(null), isTrue);
      expect(copilotInstallIsSideloaded(''), isTrue);
    });
  });

  group('CopilotTarget.fromJson', () {
    test('parses a full hit', () {
      final t = CopilotTarget.fromJson({
        'found': true,
        'x': 0.82,
        'y': 0.91,
        'w': 0.14,
        'h': 0.06,
        'label': 'Send',
        'kind': 'button',
        'confidence': 0.93,
        'say': 'Tap Send.',
      });
      expect(t.found, isTrue);
      expect(t.x, 0.82);
      expect(t.kind, CopilotTargetKind.button);
      expect(t.draftText, isNull);
    });

    test('parses a text-field draft; empty draft becomes null', () {
      final t = CopilotTarget.fromJson({
        'found': true,
        'kind': 'text_field',
        'draft_text': '  hello there  ',
        'draft_say':
            "I drafted this: 'hello there' Want me to copy it so you can paste it?",
        'copy_requires_confirmation': true,
        'say': 'Tap the box.',
      });
      expect(t.kind, CopilotTargetKind.textField);
      expect(t.draftText, 'hello there');
      // Voice flow contract rides the wire: readback + confirmation gate.
      expect(t.draftSay, contains('hello there'));
      expect(t.draftSay, contains('Want me to copy it'));
      expect(t.copyRequiresConfirmation, isTrue);
      expect(t.voiceDraftPrompt, t.draftSay);
      final empty = CopilotTarget.fromJson({
        'found': true,
        'kind': 'text_field',
        'draft_text': '   ',
      });
      expect(empty.draftText, isNull);
    });

    test('a miss carries only the guidance line', () {
      final t = CopilotTarget.fromJson({
        'found': false,
        'say': 'Scroll down first.',
      });
      expect(t.found, isFalse);
      expect(t.say, 'Scroll down first.');
    });
  });

  group('CopilotCoordinateMapper.mapTarget', () {
    const portrait = CopilotGeometry(
      displayWidthPx: 1080,
      displayHeightPx: 2400,
      frameWidthPx: 1080,
      frameHeightPx: 2400,
    );

    test('identity mapping: full-display frame, center maps 1:1', () {
      final r = CopilotCoordinateMapper.mapTarget(
        const CopilotTarget(found: true, x: 0.5, y: 0.25, w: 0.2, h: 0.1),
        portrait,
      );
      expect(r.centerX, closeTo(540, 0.001));
      expect(r.centerY, closeTo(600, 0.001));
      expect(r.width, closeTo(216, 0.001));
      expect(r.height, closeTo(240, 0.001));
    });

    test('status-bar-excluded frame offsets y by the bar height', () {
      const geo = CopilotGeometry(
        displayWidthPx: 1080,
        displayHeightPx: 2400,
        frameWidthPx: 1080,
        frameHeightPx: 2280,
        statusBarHeightPx: 120,
        frameIncludesStatusBar: false,
      );
      final r = CopilotCoordinateMapper.mapTarget(
        const CopilotTarget(found: true, x: 0.5, y: 0.0, w: 0.2, h: 0.1),
        geo,
      );
      // y=0 in frame space is the first row BELOW the status bar.
      expect(r.centerY, closeTo(120 + CopilotCoordinateMapper.minTargetPx / 2,
          CopilotCoordinateMapper.minTargetPx));
      expect(r.centerY, greaterThanOrEqualTo(120));
      final mid = CopilotCoordinateMapper.framePixelToOverlay(540, 1140, geo);
      expect(mid.$1, closeTo(540, 0.001));
      expect(mid.$2, closeTo(120 + 1140, 0.001));
    });

    test('rotation: landscape frame onto portrait display swaps axes', () {
      // Frame captured in landscape (2400x1080), display now portrait.
      const geo = CopilotGeometry(
        displayWidthPx: 1080,
        displayHeightPx: 2400,
        frameWidthPx: 2400,
        frameHeightPx: 1080,
        quarterTurns: 1,
      );
      expect(
        CopilotGeometry.impliedQuarterTurns(
          frameWidthPx: 2400,
          frameHeightPx: 1080,
          displayWidthPx: 1080,
          displayHeightPx: 2400,
        ),
        1,
      );
      // Frame point (0.25, 0.5) rotated one CW turn -> (0.5, 0.25).
      final p = CopilotCoordinateMapper.framePixelToOverlay(600, 540, geo);
      expect(p.$1, closeTo(540, 0.001));
      expect(p.$2, closeTo(600, 0.001));
      // Size fractions swap too: w comes from the target's h.
      final r = CopilotCoordinateMapper.mapTarget(
        const CopilotTarget(found: true, x: 0.25, y: 0.5, w: 0.4, h: 0.1),
        geo,
      );
      expect(r.width, closeTo(0.1 * 1080, 0.001));
      expect(r.height, closeTo(0.4 * 2400, 0.001));
    });

    test('rotateNormalized wraps and handles 180/270', () {
      expect(CopilotCoordinateMapper.rotateNormalized(0.2, 0.3, 0), (0.2, 0.3));
      expect(CopilotCoordinateMapper.rotateNormalized(0.2, 0.3, 2), (0.8, 0.7));
      expect(CopilotCoordinateMapper.rotateNormalized(0.2, 0.3, 4), (0.2, 0.3));
      final p = CopilotCoordinateMapper.rotateNormalized(0.2, 0.3, 3);
      expect(p.$1, closeTo(0.3, 1e-9));
      expect(p.$2, closeTo(0.8, 1e-9));
    });

    test('tiny targets grow to the minimum ring; edges stay on screen', () {
      final r = CopilotCoordinateMapper.mapTarget(
        const CopilotTarget(found: true, x: 0.0, y: 1.0, w: 0.01, h: 0.01),
        portrait,
      );
      expect(r.width, CopilotCoordinateMapper.minTargetPx);
      expect(r.height, CopilotCoordinateMapper.minTargetPx);
      expect(r.centerX, CopilotCoordinateMapper.minTargetPx / 2);
      expect(r.centerY, 2400 - CopilotCoordinateMapper.minTargetPx / 2);
    });
  });

  group('black-frame heuristic (mirrors the native threshold)', () {
    test('secure black frames are detected; dark-but-real frames are not', () {
      expect(copilotIsBlackFrame(0), isTrue);
      expect(copilotIsBlackFrame(kCopilotBlackLuminanceMax), isTrue);
      expect(copilotIsBlackFrame(12), isFalse); // a dark app screen at night
      expect(copilotIsBlackFrame(200), isFalse);
    });
  });
}
