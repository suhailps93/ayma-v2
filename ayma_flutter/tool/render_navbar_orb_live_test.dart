import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline visual-verification generator for the founder's third orb
/// follow-up: "the same animation should happen in the nav bar logo too" —
/// the nav-bar tab's `AymaOrb` used to render flat/static during a live call
/// because `AymaTabBar` only ever passed a plain `active: bool` (always
/// exactly `listening`, amplitude pinned at 0). Now that `AymaTabBar` maps
/// the real `VoiceSessionController` (`phase`/`agentSpeaking`/`micLevel`/
/// `aymaLevel`) the same way `VoiceCallScreen`/`SignInScreen` already do (see
/// `AymaTabBar._orbState`/`_orbAmplitude`), this renders the exact frames
/// that wiring produces at the nav bar's own 64px size — same painter, same
/// `voiceLive` gating (broadened in this batch — see
/// `render_orb_voice_live_test.dart`), same amplitude-reactive motion
/// (restored to comparable liveliness for listening in this batch — see
/// `render_orb_rim_flutter_test.dart`) — at low vs high amplitude, proving
/// the nav-bar-scale orb actually reacts to a live amplitude value changing,
/// not just a single static frame. Not part of the regular suite — run
/// explicitly:
///   flutter test tool/render_navbar_orb_live_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> render({
    required String name,
    required AymaOrbState state,
    required bool voiceLive,
    double amplitude = 0,
    double t = 0,
  }) async {
    const orbSize = 64.0;
    const canvasSize = 96.0;
    final inset = (canvasSize - orbSize) / 2;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, canvasSize, canvasSize),
      ui.Paint()..color = AymaColors.darkBg,
    );

    canvas.save();
    canvas.translate(inset, inset);
    AymaOrbPainter(
      t: t,
      fromState: state,
      toState: state,
      transitionT: 1,
      amplitude: amplitude,
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: true,
      showListeningRings: state == AymaOrbState.listening,
      voiceLive: voiceLive,
    ).paint(canvas, const ui.Size(orbSize, orbSize));
    canvas.restore();

    final picture = recorder.endRecording();
    final image =
        await picture.toImage(canvasSize.round(), canvasSize.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull);

    final file = File('build/navbar_orb_live_verification/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote ${file.path} (${bytes.lengthInBytes} bytes)');
  }

  test('render the nav-bar-scale orb across the real AymaTabBar mapping',
      () async {
    // Idle (`voice == null`, or a controller that's simply not active) —
    // exactly what the bar always rendered before any call starts.
    await render(
      name: '00_idle',
      state: AymaOrbState.idle,
      voiceLive: false,
    );

    // Connecting/waking -> AymaOrbState.thinking, voiceLive already true
    // (§ AymaTabBar._orbState maps both phases to thinking).
    await render(
      name: '01_thinking_connecting',
      state: AymaOrbState.thinking,
      voiceLive: true,
      t: 0.4,
    );

    // Listening (live, not speaking) at low vs high mic level — same
    // pulse-peak `t` `render_orb_rim_flutter_test.dart` uses
    // (sin(t * 1.3 * 1.25) ~ 1) so the amplitude difference isn't masked by
    // also being mid-cycle on the motion itself.
    const tListenPeak = 0.967;
    await render(
      name: '02_listening_amp_low',
      state: AymaOrbState.listening,
      voiceLive: true,
      amplitude: 0.05,
      t: tListenPeak,
    );
    await render(
      name: '03_listening_amp_high',
      state: AymaOrbState.listening,
      voiceLive: true,
      amplitude: 1.0,
      t: tListenPeak,
    );

    // Speaking (live, agentSpeaking) at low vs high Ayma-output level — same
    // flutter-peak `t` as the rim-flutter tool (sin(t * 9.5 * 1.55) ~ 1).
    const tSpeakPeak = 0.1068;
    await render(
      name: '04_speaking_amp_low',
      state: AymaOrbState.speaking,
      voiceLive: true,
      amplitude: 0.05,
      t: tSpeakPeak,
    );
    await render(
      name: '05_speaking_amp_high',
      state: AymaOrbState.speaking,
      voiceLive: true,
      amplitude: 1.0,
      t: tSpeakPeak,
    );
  });
}
