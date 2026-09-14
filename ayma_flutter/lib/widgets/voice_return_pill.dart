import 'package:flutter/material.dart';

import '../services/voice_session_controller.dart';
import '../theme.dart';
import 'ayma_orb.dart';

/// The small "your call is still going" pill pinned to the top of the app
/// shell whenever a live Ayma voice session is running and the user has
/// stepped away to another tab — the chat tab's own composer already fully
/// represents the call there, so this exists only to give every *other* tab a
/// visible, tappable way back to it.
///
/// Purely presentational: [voice] is read on every rebuild (the caller wraps
/// this in a `ListenableBuilder` on the same shell-owned controller, never a
/// second instance), [visible] is decided by the caller (call active AND not
/// already on the Ayma tab), and tapping fires [onTap] — the same tab switch
/// the nav bar's own Ayma icon already performs.
class VoiceReturnPill extends StatelessWidget {
  const VoiceReturnPill({
    super.key,
    required this.voice,
    required this.visible,
    required this.onTap,
  });

  final VoiceSessionController voice;
  final bool visible;
  final VoidCallback onTap;

  static const _slideOut = Offset(0, -0.6);

  AymaOrbState _orbState() {
    return switch (voice.phase) {
      VoiceSessionPhase.connecting || VoiceSessionPhase.waking =>
        AymaOrbState.thinking,
      VoiceSessionPhase.live =>
        voice.agentSpeaking ? AymaOrbState.speaking : AymaOrbState.listening,
      VoiceSessionPhase.idle || VoiceSessionPhase.error => AymaOrbState.idle,
    };
  }

  String _label() {
    return switch (voice.phase) {
      VoiceSessionPhase.connecting || VoiceSessionPhase.waking =>
        'Connecting…',
      VoiceSessionPhase.live => voice.muted
          ? 'Muted'
          : (voice.agentSpeaking
              ? 'Ayma is speaking…'
              : (voice.activeToolLabel ?? 'Ayma is listening…')),
      VoiceSessionPhase.idle || VoiceSessionPhase.error => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final pill = Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Tooltip(
            message: 'Return to your Ayma call',
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 16, 8),
              decoration: BoxDecoration(
                color: ac.bgElev,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: ac.lineSoft, width: 0.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AymaOrb(size: 18, state: _orbState()),
                  const SizedBox(width: 8),
                  Text(_label(), style: AymaType.sans(size: 12.5, color: ac.fg)),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return ExcludeSemantics(
      excluding: !visible,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          offset: visible ? Offset.zero : _slideOut,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            opacity: visible ? 1 : 0,
            child: SafeArea(
              bottom: false,
              // A `Row` here (not `Align`/`Center`) so this widget's own size
              // stays tight to the pill's actual height instead of expanding
              // to fill the whole shell `Stack` — otherwise hit-testing (and
              // widget-test taps) would target the middle of the screen
              // rather than the small pill actually painted at the top.
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [pill],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
