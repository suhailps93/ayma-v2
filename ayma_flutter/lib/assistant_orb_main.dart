import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'firebase_options.dart';
import 'services/accent_color_controller.dart';
import 'services/app_context.dart';
import 'services/assist_context.dart';
import 'services/assistant_service.dart';
import 'services/ayma_session.dart';
import 'services/voice_session_controller.dart';
import 'theme.dart';
import 'widgets/ayma_orb.dart';

/// Dedicated Flutter entrypoint for the **floating Ayma orb** a default-assistant
/// summon raises OVER the current app (founder order, Nov 2026).
///
/// A summon (long-press Home / assistant gesture) is handled by
/// `AymaAssistantSession` (Android `VoiceInteractionSession`). Instead of
/// launching the full app Activity, the session hosts a `FlutterView` backed by
/// a FlutterEngine running THIS entrypoint, in the session's own window over the
/// foreground app. The orb runs the real Ayma voice stack
/// ([VoiceSessionController] on LiveKit) and the real [AymaOrb] widget — nothing
/// is reimplemented. Dismissing returns the user to the app they were in.
///
/// This engine is intentionally minimal: it inits Firebase, restores the
/// signed-in session from disk, and starts a voice session. It never runs the
/// full startup DAG or the app router — the orb is a single overlay surface,
/// not the app.
@pragma('vm:entry-point')
Future<void> assistantOrbMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    // A duplicate-app or transient init error must not crash the overlay; the
    // orb falls back to its honest "sign in first" / "can't connect" state.
    debugPrint('assistantOrbMain: Firebase init warning: $e');
  }
  // Pull the saved accent so the orb paints in the user's own colour (defaults
  // to Cherry Fuchsia until the local pref loads).
  unawaited(accentColorControllerGlobal.syncRemote());
  runApp(const AssistantOrbApp());
}

/// Root of the floating-orb overlay. Transparent scaffold so only the orb (and,
/// when expanded, a dimming scrim) paints over the foreground app.
class AssistantOrbApp extends StatelessWidget {
  const AssistantOrbApp({super.key, this.model});

  /// Injected in tests; the running overlay builds the real voice-backed model.
  final AssistantOrbModel? model;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: accentColorControllerGlobal,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AymaTheme.lightWithAccent(accentColorControllerGlobal.color),
        darkTheme: AymaTheme.darkWithAccent(accentColorControllerGlobal.color),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: AssistantOrbSurface(model: model),
        ),
      ),
    );
  }
}

/// The orb's view-model: everything the surface renders, independent of the
/// voice stack so the surface stays unit-testable with a fake.
abstract class AssistantOrbModel extends ChangeNotifier {
  /// Drives the orb's internal motion — idle / listening / speaking / thinking.
  AymaOrbState get orbState;

  /// Live amplitude for the orb's reactive pulse (mic while listening, Ayma's
  /// output while speaking).
  ValueListenable<double> get amplitude;

  /// True only while the call is genuinely live (gates the "connected" glow).
  bool get voiceLive;

  /// The honest one-line status (never a fake "Listening" when the brain can't
  /// respond — AGENTS.md).
  String get statusLabel;

  /// Non-null when voice could not run (LiveKit down, signed out, …). The orb
  /// shows this instead of pretending to listen.
  String? get errorText;

  /// Whether the expanded voice panel is showing (vs. the small floating orb).
  bool get expanded;

  bool get muted;

  void toggleExpanded();

  void toggleMute();

  /// Ends the voice session and closes the overlay, returning to the app.
  void dismiss();
}

/// Maps the voice controller's state to the orb's visual state — pure, so the
/// three required states (idle / listening / speaking) are tested without a
/// live controller.
AymaOrbState assistantOrbStateFrom({
  required VoiceSessionPhase phase,
  required bool agentSpeaking,
  bool reconnecting = false,
  bool micYielded = false,
}) =>
    switch (phase) {
      VoiceSessionPhase.connecting ||
      VoiceSessionPhase.waking =>
        AymaOrbState.thinking,
      VoiceSessionPhase.live => reconnecting
          ? AymaOrbState.thinking
          : (agentSpeaking
              ? AymaOrbState.speaking
              : (micYielded ? AymaOrbState.idle : AymaOrbState.listening)),
      _ => AymaOrbState.idle,
    };

/// The real, voice-backed model: binds [AymaSession.instance.voice] (LiveKit)
/// and the native dismiss channel.
class VoiceOrbModel extends AssistantOrbModel {
  VoiceOrbModel({
    VoiceSessionController? voice,
    AssistantOrbService? service,
  })  : _voice = voice ?? AymaSession.instance.voice,
        _service = service ?? AssistantOrbService.instance {
    _voice.addListener(_onVoice);
  }

  final VoiceSessionController _voice;
  final AssistantOrbService _service;

  bool _expanded = false;
  bool _disposed = false;
  bool _signedOut = false;

  void _onVoice() {
    if (!_disposed) notifyListeners();
  }

  /// Fold the captured screen into context and start the LiveKit voice session.
  /// Never lands on the in-app assistant screen — this IS the summon surface.
  Future<void> activate() async {
    // The native session stores the snapshot ~450ms into the summon (after the
    // assist/screenshot flush window), while this engine is already booting, so
    // poll briefly for it rather than racing the one read.
    AssistCapture? capture;
    for (var i = 0; i < 8 && capture == null; i++) {
      capture = await AssistantService.instance.takePendingAssist();
      if (capture == null) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    final snap = capture?.snapshot;
    if (snap != null && snap.hasScreenContent) {
      AppContext.instance.set(
        screen: 'external_app',
        subjectName: snap.friendlyAppName,
        note: snap.foregroundPackage,
        detail: snap.detailSummary(),
      );
    }
    if (FirebaseAuth.instance.currentUser == null) {
      // Honest state: a summon before sign-in can't start voice. Wait briefly
      // for the persisted session to restore from disk, then give up with a
      // visible message rather than a silent, dead orb.
      try {
        await FirebaseAuth.instance
            .authStateChanges()
            .firstWhere((u) => u != null)
            .timeout(const Duration(seconds: 6));
      } on TimeoutException {
        _signedOut = true;
        if (!_disposed) notifyListeners();
        return;
      }
    }
    // start() is idempotent and self-contained; a failure (e.g. LiveKit 429)
    // surfaces through the controller's error state, never as a silent hang.
    try {
      await _voice.start();
    } catch (_) {
      // The controller already recorded the honest error; the UI reads it.
    }
  }

  @override
  AymaOrbState get orbState => assistantOrbStateFrom(
        phase: _voice.phase,
        agentSpeaking: _voice.agentSpeaking,
        reconnecting: _voice.reconnecting,
        micYielded: _voice.micYielded,
      );

  @override
  ValueListenable<double> get amplitude =>
      _voice.agentSpeaking ? _voice.aymaLevel : _voice.micLevel;

  @override
  bool get voiceLive => _voice.isListening && !_voice.reconnecting;

  @override
  String get statusLabel {
    if (_signedOut) return 'Sign in to Ayma to talk here';
    final err = errorText;
    if (err != null) return err;
    return switch (_voice.phase) {
      VoiceSessionPhase.connecting =>
        _voice.relayRetrying ? 'Reconnecting…' : 'Connecting…',
      VoiceSessionPhase.waking => 'Waking Ayma…',
      VoiceSessionPhase.live => _voice.muted
          ? 'Muted'
          : (_voice.reconnecting
              ? 'Reconnecting…'
              : (_voice.agentSpeaking
                  ? 'Ayma is speaking…'
                  : (_voice.awaitingFirstResponse
                      ? 'Connecting…'
                      : 'Listening…'))),
      _ => 'Tap to talk to Ayma',
    };
  }

  @override
  String? get errorText {
    if (_signedOut) return 'Sign in to Ayma to talk here';
    if (_voice.phase == VoiceSessionPhase.error) {
      return _voice.errorMessage ?? "Ayma can't connect right now";
    }
    return null;
  }

  @override
  bool get expanded => _expanded;

  @override
  bool get muted => _voice.muted;

  @override
  void toggleExpanded() {
    _expanded = !_expanded;
    notifyListeners();
  }

  @override
  void toggleMute() => unawaited(_voice.toggleMute());

  @override
  void dismiss() {
    unawaited(_voice.stop());
    _service.dismiss();
  }

  @override
  void dispose() {
    _disposed = true;
    _voice.removeListener(_onVoice);
    super.dispose();
  }
}

/// The floating-orb surface: a small, tappable orb over the current app that
/// expands to the full voice panel and dismisses back to that app.
class AssistantOrbSurface extends StatefulWidget {
  const AssistantOrbSurface({super.key, this.model});

  final AssistantOrbModel? model;

  @override
  State<AssistantOrbSurface> createState() => _AssistantOrbSurfaceState();
}

class _AssistantOrbSurfaceState extends State<AssistantOrbSurface> {
  late final AssistantOrbModel _model;
  bool _ownsModel = false;

  @override
  void initState() {
    super.initState();
    final injected = widget.model;
    if (injected != null) {
      _model = injected;
    } else {
      final real = VoiceOrbModel();
      _model = real;
      _ownsModel = true;
      unawaited(real.activate());
    }
  }

  @override
  void dispose() {
    if (_ownsModel) _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _model,
      builder: (context, _) =>
          _model.expanded ? _expanded(context) : _collapsed(context),
    );
  }

  /// The resting state: a transparent full-bounds dismiss-catcher with a small
  /// orb floating near the bottom. Tapping the orb expands; tapping anywhere
  /// else returns to the app.
  Widget _collapsed(BuildContext context) {
    final ac = context.ac;
    final err = _model.errorText;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const Key('assistantOrbDismiss'),
            behavior: HitTestBehavior.translucent,
            onTap: _model.dismiss,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 48,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (err != null)
                Container(
                  key: const Key('assistantOrbError'),
                  margin: const EdgeInsets.only(bottom: 12),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: ac.bgCard,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: ac.lineSoft),
                  ),
                  child: Text(
                    err,
                    style: AymaType.sans(size: 12, color: ac.fg),
                  ),
                ),
              GestureDetector(
                key: const Key('assistantOrbTap'),
                onTap: _model.toggleExpanded,
                child: AymaOrb(
                  key: const Key('assistantOrb'),
                  size: 96,
                  state: _model.orbState,
                  amplitudeListenable: _model.amplitude,
                  voiceLive: _model.voiceLive,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The expanded voice panel: a dimming scrim, a large reactive orb, the honest
  /// status line, mute, and controls to collapse or end + return to the app.
  Widget _expanded(BuildContext context) {
    final ac = context.ac;
    return Stack(
      key: const Key('assistantOrbExpanded'),
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _model.toggleExpanded,
            child: Container(color: ac.bg.withValues(alpha: 0.92)),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AymaOrb(
                size: 220,
                state: _model.orbState,
                amplitudeListenable: _model.amplitude,
                voiceLive: _model.voiceLive,
              ),
              const SizedBox(height: 28),
              Text(
                _model.statusLabel,
                style: AymaType.mono(size: 12, color: ac.fgMute)
                    .copyWith(letterSpacing: 2),
              ),
              const SizedBox(height: 28),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const Key('assistantOrbMute'),
                    icon: Icon(
                      _model.muted ? Icons.mic_off : Icons.mic,
                      color: _model.muted ? AymaColors.error : ac.fgDim,
                    ),
                    tooltip: _model.muted ? 'Unmute' : 'Mute',
                    onPressed: _model.toggleMute,
                  ),
                  const SizedBox(width: 24),
                  IconButton(
                    key: const Key('assistantOrbEnd'),
                    icon: const Icon(Icons.call_end, color: AymaColors.error),
                    tooltip: 'End and return',
                    onPressed: _model.dismiss,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Dart side of the floating orb's own native channel (`ayma/assistant_orb`):
/// just the dismiss signal that tears the session window down and returns the
/// user to the app they summoned Ayma from. The screen-capture read stays on
/// the existing `ayma/assistant` channel ([AssistantService]).
class AssistantOrbService {
  AssistantOrbService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'ayma/assistant_orb';

  static final AssistantOrbService instance = AssistantOrbService();

  final MethodChannel _channel;

  /// Asks the native session to finish, closing the overlay window.
  Future<void> dismiss() async {
    try {
      await _channel.invokeMethod<void>('dismiss');
    } on PlatformException {
      // Nothing to close (e.g. tests).
    } on MissingPluginException {
      // Same.
    }
  }
}
