import 'package:flutter/material.dart';

import '../services/voice_session_controller.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/ayma_quiet_chip.dart';
import '../widgets/out_of_credits.dart';

/// The founder's "voice-only mode" (2026-09-25 ask): a full-screen,
/// phone-call-style presentation of an already-connecting-or-live voice
/// session — no transcript, no composer, just a large [AymaOrb] reacting to
/// the same [VoiceSessionController] signals the chat screen's inline
/// composer bar already reads (`phase`, `agentSpeaking`, `micLevel`/
/// `aymaLevel`), plus a close button to step back to normal text chat.
///
/// This is a pure presentation layer over [voice] — it never starts, stops,
/// or mutes the call itself (see `ChatScreen._toggleVoice` for that). Closing
/// this screen (the X button, or the system back gesture) only pops back to
/// chat; the call keeps running exactly like switching tabs mid-call already
/// does elsewhere in the app (`CallBackgroundService`, the floating "return
/// to call" launcher) — dismissing a *view* of a call must never be mistaken
/// for hanging up on it. Re-entry (from the chat composer's live-call bar, or
/// any other caller) is just pushing this screen again over the same
/// [voice] instance — there's no separate "resume" state to restore.
///
/// If the call itself ends or fails while this is open (the agent never
/// picks up, a dropped connection, a hangup from elsewhere in the app …),
/// there's nothing useful left to show here — [_onVoiceChange] pops the
/// screen automatically so the user lands back on `ChatScreen`, which already
/// owns all of that error/idle handling (the red banner, the out-of-credits
/// card, snackbars) — no duplicate error UI is built here.
class VoiceCallScreen extends StatefulWidget {
  const VoiceCallScreen({super.key, required this.voice});

  final VoiceSessionController voice;

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> {
  @override
  void initState() {
    super.initState();
    widget.voice.addListener(_onVoiceChange);
  }

  @override
  void dispose() {
    widget.voice.removeListener(_onVoiceChange);
    super.dispose();
  }

  void _onVoiceChange() {
    if (!mounted) return;
    final phase = widget.voice.phase;
    if (phase == VoiceSessionPhase.idle || phase == VoiceSessionPhase.error) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      backgroundColor: ac.bg,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.voice,
          builder: (context, _) {
            final voice = widget.voice;
            final phase = voice.phase;
            final speaking = voice.agentSpeaking;
            final orbState = switch (phase) {
              VoiceSessionPhase.connecting ||
              VoiceSessionPhase.waking => AymaOrbState.thinking,
              VoiceSessionPhase.live =>
                speaking ? AymaOrbState.speaking : AymaOrbState.listening,
              _ => AymaOrbState.idle,
            };
            final label = switch (phase) {
              // The ice-relay-retry (a second connect attempt with TURN
              // relay forced) shows as "Reconnecting…" on the same line.
              VoiceSessionPhase.connecting =>
                voice.relayRetrying ? 'Reconnecting…' : 'Connecting…',
              VoiceSessionPhase.waking => 'Waking Ayma…',
              VoiceSessionPhase.live => voice.muted
                  ? 'Muted'
                  : (speaking
                        ? 'Ayma is speaking…'
                        : (voice.activeToolLabel ?? 'Listening…')),
              _ => '',
            };
            return Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AymaOrb(
                        key: const Key('voiceCallOrb'),
                        size: 220,
                        state: orbState,
                        amplitudeListenable: speaking
                            ? voice.aymaLevel
                            : voice.micLevel,
                        // This screen only ever exists for a genuinely
                        // live-or-connecting call (see the class doc), so the
                        // "connected" filament glow (founder ask: present for
                        // the whole call, not just while Ayma is talking —
                        // see `AymaOrbPainter._connectedGlowIntensity`)
                        // belongs here at every phase this screen shows.
                        voiceLive: true,
                      ),
                      const SizedBox(height: 32),
                      Text(
                        label,
                        style: AymaType.mono(size: 12, color: ac.fgMute)
                            .copyWith(letterSpacing: 2),
                      ),
                      if (voice.aymaQuiet && phase == VoiceSessionPhase.live)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(24, 16, 24, 0),
                          child: AymaQuietChip(),
                        ),
                    ],
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: IconButton(
                    icon: Icon(Icons.close, size: 26, color: ac.fgDim),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
                // Mute toggle, bottom center (founder ask, 2026-09-26). The
                // state lives on [voice] itself ([VoiceSessionController.muted]
                // / `toggleMute()`, which flips the LiveKit local mic track and
                // never touches the call), so it survives this screen being
                // closed and reopened mid-call, and stays in sync with the
                // chat composer's own inline mute button. Same mic/mic-off
                // icon pair as that composer button; the muted treatment is a
                // filled error-red circle so the state is unmistakable at a
                // glance against the near-black backdrop.
                Positioned(
                  left: 0,
                  right: 0,
                  // Inside the Scaffold's SafeArea, so the device's own bottom
                  // inset is already accounted for — this is just breathing
                  // room above it.
                  bottom: 28,
                  child: Center(
                    child: _MuteButton(
                      muted: voice.muted,
                      onTap: voice.toggleMute,
                    ),
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

/// The full-screen voice view's round mic-mute toggle: a subtle dark-surface
/// circle while live (fits the near-black immersive backdrop), flipping to a
/// filled error-red circle with a mic-off icon while muted. Purely a control
/// over [VoiceSessionController.toggleMute] — it never ends or disrupts the
/// call.
class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onTap});

  final bool muted;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Tooltip(
      message: muted ? 'Unmute' : 'Mute',
      child: Material(
        key: const Key('voiceCallMuteButton'),
        color: muted ? ac.error : ac.bgElev,
        shape: CircleBorder(
          side: BorderSide(
            color: muted ? ac.error : ac.lineSoft,
            width: 1,
          ),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 64,
            height: 64,
            child: Icon(
              muted ? Icons.mic_off_rounded : Icons.mic_rounded,
              size: 28,
              color: muted ? AymaColors.onAccentFor(ac.error) : ac.fgDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// Toggles a voice call on [voice] without leaving the current page — the
/// nav-bar orb's 1-second hold (see `AymaTabBar.onOrbLongPress`): starts one
/// when idle, ends the live one otherwise; the orb itself switches state.
/// Start uses the same error handling as `ChatScreen._toggleVoice`: a failed
/// start surfaces its message (or the out-of-credits card).
Future<void> toggleVoiceCall(
  BuildContext context,
  VoiceSessionController voice,
) async {
  if (voice.isActive) {
    await voice.stop();
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  await voice.start();
  if (voice.phase == VoiceSessionPhase.error && voice.errorMessage != null) {
    if (!context.mounted) return;
    if (voice.cappedError) {
      showOutOfCreditsSheet(context);
    } else {
      messenger.showSnackBar(SnackBar(content: Text(voice.errorMessage!)));
    }
  }
}
