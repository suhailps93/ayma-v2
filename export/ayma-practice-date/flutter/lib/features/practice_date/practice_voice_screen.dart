import 'package:flutter/material.dart';

import '../../services/api_client.dart';
import '../../services/transcript_store.dart';
import '../../services/voice_session_controller.dart';
import '../../theme.dart';
import '../../widgets/ayma_orb.dart';
import '../../widgets/overflow_guards.dart';

/// Practice Date VOICE simulator (hackathon deliverable B).
///
/// Reuses the existing LiveKit voice pipeline — a [VoiceSessionController] in
/// practice mode ([VoiceSessionController.practiceOtherUid]) connects via
/// `POST /practice/voice/start`, which seeds the room with a persona built only
/// from the match's viewer-visible profile. The persona speaks as that person;
/// Ayma's live coach is surfaced here OUT of character as a side hint
/// ([VoiceSessionController.coachHint]) over the persona's voice, so the
/// simulation immersion is never broken. A persistent header keeps it honest
/// ("you're talking to a simulation").
///
/// Ends by popping its [VoiceSessionController.practiceSessionId] back to the
/// caller (the text simulator), which then opens the debrief for it. On an
/// error (out of credits, agent never joined, dropped) it pops `null` and the
/// caller stays on the text simulator.
class PracticeVoiceScreen extends StatefulWidget {
  const PracticeVoiceScreen({
    super.key,
    required this.uid,
    this.name = '',
    this.voice,
    this.api,
  });

  /// The match being practised with.
  final String uid;

  /// Their name, for an instant header before `/practice/voice/start` returns
  /// the authoritative persona.
  final String name;

  /// Injectable for tests; otherwise a practice-mode controller is built here.
  final VoiceSessionController? voice;
  final ApiClient? api;

  @override
  State<PracticeVoiceScreen> createState() => _PracticeVoiceScreenState();
}

class _PracticeVoiceScreenState extends State<PracticeVoiceScreen> {
  late final bool _ownsVoice = widget.voice == null;
  late final VoiceSessionController _voice = widget.voice ??
      VoiceSessionController(
        transcriptStore: TranscriptStore(),
        practiceOtherUid: widget.uid,
        apiClient: widget.api,
      );

  /// Guards the single pop (End, idle timeout, or error) so a burst of
  /// controller notifications can't pop the route twice.
  bool _left = false;

  @override
  void initState() {
    super.initState();
    _voice.addListener(_onVoiceChange);
    if (!_voice.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_voice.isActive) _voice.start();
      });
    }
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoiceChange);
    if (_ownsVoice) {
      // We built it, so we stop + dispose it. (An injected controller is owned
      // by whoever passed it in — a test.)
      _voice.stop();
      _voice.dispose();
    }
    super.dispose();
  }

  void _onVoiceChange() {
    if (!mounted || _left) return;
    final phase = _voice.phase;
    if (phase == VoiceSessionPhase.error) {
      // Out of credits / agent never joined / dropped: show the reason on the
      // caller's surface, then leave (there is nothing to debrief).
      final capped = _voice.cappedError;
      final message = _voice.errorMessage;
      final messenger = ScaffoldMessenger.maybeOf(context);
      _leave(null);
      if (!capped && message != null) {
        messenger?.showSnackBar(SnackBar(content: Text(message)));
      }
    } else if (phase == VoiceSessionPhase.idle) {
      // The call ended on its own (user hung up elsewhere, or idle timeout).
      _leave(_voice.practiceSessionId);
    } else {
      setState(() {});
    }
  }

  /// End the call (if still live) and pop back with the practice session id so
  /// the caller can open the debrief; [sessionId] is null/empty on an error.
  Future<void> _end() async {
    if (_left) return;
    final sid = _voice.practiceSessionId;
    await _voice.stop(); // -> idle; _onVoiceChange would also pop, _left guards
    _leave(sid);
  }

  void _leave(String? sessionId) {
    if (_left || !mounted) return;
    _left = true;
    Navigator.of(context).maybePop(
        (sessionId != null && sessionId.isNotEmpty) ? sessionId : null);
  }

  String get _personaName {
    final n = _voice.practicePersona?.name ?? '';
    return n.isNotEmpty ? n : widget.name;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      backgroundColor: ac.bg,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _voice,
          builder: (context, _) {
            final phase = _voice.phase;
            final speaking = _voice.agentSpeaking;
            final orbState = switch (phase) {
              VoiceSessionPhase.connecting ||
              VoiceSessionPhase.waking =>
                AymaOrbState.thinking,
              VoiceSessionPhase.live =>
                speaking ? AymaOrbState.speaking : AymaOrbState.listening,
              _ => AymaOrbState.idle,
            };
            final status = switch (phase) {
              VoiceSessionPhase.connecting =>
                _voice.relayRetrying ? 'Reconnecting…' : 'Connecting…',
              VoiceSessionPhase.waking => 'Setting up the simulation…',
              VoiceSessionPhase.live => speaking
                  ? '$_personaName is speaking…'
                  : (_voice.muted ? 'Muted' : 'Your turn — speak'),
              _ => '',
            };
            return Column(
              children: [
                _SimulationHeader(name: _personaName, onEnd: _end),
                Expanded(
                  child: CenteredScroll(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AymaOrb(
                          key: const Key('practiceVoiceOrb'),
                          size: 200,
                          state: orbState,
                          amplitudeListenable:
                              speaking ? _voice.aymaLevel : _voice.micLevel,
                          voiceLive: true,
                        ),
                        const SizedBox(height: 28),
                        Text(
                          status,
                          style: AymaType.mono(size: 12, color: ac.fgMute)
                              .copyWith(letterSpacing: 2),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_voice.coachHint.isNotEmpty)
                  _CoachHint(text: _voice.coachHint),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _RoundButton(
                        key: const Key('practiceVoiceMuteButton'),
                        icon: _voice.muted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded,
                        tint: _voice.muted ? ac.error : ac.bgElev,
                        iconColor: _voice.muted
                            ? AymaColors.onAccentFor(ac.error)
                            : ac.fgDim,
                        onTap: _voice.toggleMute,
                      ),
                      const SizedBox(width: 28),
                      _RoundButton(
                        key: const Key('practiceVoiceEndButton'),
                        icon: Icons.call_end_rounded,
                        tint: ac.error,
                        iconColor: AymaColors.onAccentFor(ac.error),
                        onTap: _end,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The persistent "this is a practice simulation" header, with an End affordance.
class _SimulationHeader extends StatelessWidget {
  const _SimulationHeader({required this.name, required this.onEnd});
  final String name;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      key: const Key('practiceVoiceBanner'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      color: ac.accentFaint,
      child: Row(
        children: [
          Icon(Icons.theater_comedy_outlined, size: 18, color: ac.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name.isEmpty
                  ? "Practice call — you're talking to a simulation, not a real person."
                  : "Practice call — you're talking to a simulated version of $name, not the real person.",
              style: AymaType.sans(size: 12.5, color: ac.fg, height: 1.3),
            ),
          ),
          TextButton(
            key: const Key('practiceVoiceEndTextButton'),
            onPressed: onEnd,
            child: Text('End',
                style: AymaType.sans(
                    size: 15, weight: FontWeight.w600, color: ac.accent)),
          ),
        ],
      ),
    );
  }
}

/// The out-of-character live coach nudge, shown just above the call controls —
/// deliberately distinct from the persona's voice.
class _CoachHint extends StatelessWidget {
  const _CoachHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      key: const Key('practiceVoiceCoachHint'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: ac.accentSoft,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, size: 16, color: ac.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: AymaType.sans(size: 13, color: ac.fg, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.tint,
    required this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final Color tint;
  final Color iconColor;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Material(
      color: tint,
      shape: CircleBorder(side: BorderSide(color: ac.lineSoft, width: 1)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 60,
          height: 60,
          child: Icon(icon, size: 26, color: iconColor),
        ),
      ),
    );
  }
}
