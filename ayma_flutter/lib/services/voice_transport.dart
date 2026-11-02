import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

/// One transcript segment relayed by the agent over the room data channel
/// (§1.6). [topic] is `user_transcript` or `agent_transcript`.
class TranscriptSegment {
  const TranscriptSegment({
    required this.topic,
    required this.text,
    required this.isFinal,
  });

  final String topic;
  final String text;
  final bool isFinal;
}

/// A skill/tool call starting or finishing during a voice turn (§1.7 step 3)
/// — the voice equivalent of the text chat's status -> reply kicker. [phase]
/// is `start` (live, present-progressive [label], e.g. "Researching…") or
/// `end` (settled, past-tense [label], e.g. "Researched them online").
class ToolUsedEvent {
  const ToolUsedEvent({
    required this.name,
    required this.label,
    required this.phase,
  });

  final String name;
  final String label;
  final String phase;

  bool get isStart => phase == 'start';
}

const _userTranscriptTopic = 'user_transcript';
const _agentTranscriptTopic = 'agent_transcript';
const _agentStateTopic = 'agent_state';
const _toolUsedTopic = 'tool_used';
const _callEndingTopic = 'call_ending';
const _agentMuteTopic = 'agent_mute';
const _agentMuteControlTopic = 'agent_mute_control';
const _voiceAccentControlTopic = 'voice_accent_control';
const _practiceCoachTopic = 'practice_coach';
const _voiceStatusTopic = 'voice_status';

/// Narrow seam over the LiveKit room so [VoiceSessionController] and its tests
/// never touch `livekit_client` directly (ARCHITECTURE.md §1.7 step 5).
///
/// Step 14 needs only: join a room, publish the mic, hear the agent, mute,
/// leave. Transcript data-channel events (§1.6) are Step 15.
abstract class VoiceTransport {
  /// Emits `true` exactly once, the first time the agent (Ayma) is genuinely
  /// present in the room and we can hear it — a remote audio track subscription,
  /// or an `agent_state` data message as a fallback. One-shot latch: never
  /// emits again and never emits `false`. Lets the controller hold a `waking`
  /// phase while a scale-to-zero worker cold-starts instead of claiming
  /// "Listening" the moment the room connects (§1.7).
  Stream<bool> get agentReady;

  /// Emits `true` while a remote participant (the agent) is actively speaking.
  Stream<bool> get agentSpeaking;

  /// The local mic input level, 0..1, sampled a few times a second. Drives the
  /// bottom edge of the voice-mode composer waveform.
  Stream<double> get localAudioLevel;

  /// The agent's output audio level, 0..1, sampled the same way — the actual
  /// amplitude envelope of Ayma's voice, not a speaking boolean.
  Stream<double> get agentAudioLevel;

  /// Emits `user_transcript` / `agent_transcript` segments from the agent.
  Stream<TranscriptSegment> get transcripts;

  /// Emits a `tool_used` start/end event each time the agent invokes a skill
  /// mid-call (§1.7 step 3).
  Stream<ToolUsedEvent> get toolEvents;

  /// Emits the reason string (currently only `out_of_credits`, §F3) the agent
  /// sent right before it deliberately ended the call itself — distinct from
  /// [closed], which also fires for an ordinary dropped connection. Always
  /// emitted (if at all) shortly *before* [closed] for the same disconnect,
  /// so a listener should act on this first.
  Stream<String> get callEnding;

  /// Emits `true` when the agent has been told to "shut up" and goes quiet,
  /// `false` when she is called back by name (topic `agent_mute`).
  Stream<bool> get agentMute;

  /// Practice Date voice (hackathon B): an out-of-character live coaching nudge
  /// to the USER (topic `practice_coach`), shown as a side hint — never spoken
  /// by the simulated persona. Emits only final hint text. Empty on a normal
  /// (non-practice) call.
  Stream<String> get practiceCoach;

  /// Honest voice-stack status (topic `voice_status`, payload `{"state"}`).
  /// Used for the open-weights (self-hosted Modal) cold start: emits
  /// `open_weights_warming` on session start so the UI shows a specific
  /// "warming up — first reply can take a minute or two" and extends its
  /// no-first-response budget, instead of a silent "Listening…" (§13.9).
  Stream<String> get voiceStatus;

  /// Asks the agent to change its "shut up" state (topic
  /// `agent_mute_control`, payload `{"muted": bool}`). The agent only honours
  /// `muted: false` (the user tapped Unmute) and always answers on
  /// [agentMute], which stays the single source of truth.
  Future<void> sendAgentMuteControl({required bool muted});

  /// Tells the live agent the voice settings were saved mid-call (topic
  /// `voice_accent_control`, payload `{"accent", "language"}` — the saved
  /// free-text accent and language label, §13.9). The agent hot-swaps the
  /// running session to them instead of waiting for the next call.
  Future<void> sendVoiceAccentControl({
    required String accent,
    required String language,
  });

  /// Emits once if the transport drops unexpectedly (network / server close).
  Stream<Object> get closed;

  /// [forceRelay] forces the WebRTC ICE transport policy to TURN relay —
  /// LiveKit Cloud serves TURN over TLS/443, which survives UDP-blocking
  /// networks. Used only by the controller's one-shot ice-relay-retry after
  /// a first attempt dies with an ICE-connectivity timeout
  /// ([isIceConnectivityFailure]).
  Future<void> connect({
    required String url,
    required String token,
    bool forceRelay = false,
  });

  Future<void> setMicrophoneEnabled(bool enabled);

  Future<void> disconnect();

  Future<void> dispose();
}

/// True when [error] is LiveKit's "the PeerConnection never reached
/// connected" failure — client ↔ LiveKit Cloud ICE connectivity, typically a
/// UDP-blocking network. This is the (and the only) failure worth one
/// automatic retry with `forceRelay: true`; a bad token / unreachable server
/// ([ConnectException]) would fail identically over relay. Lives here so
/// [VoiceSessionController] never has to import `livekit_client` itself.
bool isIceConnectivityFailure(Object error) => error is MediaConnectException;

/// Real transport backed by a LiveKit [Room].
class LiveKitVoiceTransport implements VoiceTransport {
  LiveKitVoiceTransport();

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  Timer? _levelTimer;
  final _agentReady = StreamController<bool>.broadcast();
  final _agentSpeaking = StreamController<bool>.broadcast();
  final _transcripts = StreamController<TranscriptSegment>.broadcast();
  final _toolEvents = StreamController<ToolUsedEvent>.broadcast();
  final _callEnding = StreamController<String>.broadcast();
  final _agentMute = StreamController<bool>.broadcast();
  final _practiceCoach = StreamController<String>.broadcast();
  final _voiceStatus = StreamController<String>.broadcast();
  final _closed = StreamController<Object>.broadcast();
  final _localLevel = StreamController<double>.broadcast();
  final _agentLevel = StreamController<double>.broadcast();

  /// Latched the first time [_markAgentReady] fires, so a later track / state
  /// event is a no-op (§1.7 — the readiness signal is one-shot).
  bool _agentReadyLatched = false;

  @override
  Stream<bool> get agentReady => _agentReady.stream;

  @override
  Stream<bool> get agentSpeaking => _agentSpeaking.stream;

  @override
  Stream<double> get localAudioLevel => _localLevel.stream;

  @override
  Stream<double> get agentAudioLevel => _agentLevel.stream;

  /// Poll the LiveKit participants' `audioLevel` (already 0..1) a few times a
  /// second — robust across SDK versions and gives a real amplitude envelope
  /// rather than an on/off speaking flag.
  void _startLevelSampling() {
    _levelTimer?.cancel();
    _levelTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      final room = _room;
      if (room == null) return;
      final local = room.localParticipant?.audioLevel ?? 0.0;
      var agent = 0.0;
      for (final p in room.remoteParticipants.values) {
        if (p.audioLevel > agent) agent = p.audioLevel;
      }
      if (!_localLevel.isClosed) _localLevel.add(local.clamp(0.0, 1.0));
      if (!_agentLevel.isClosed) _agentLevel.add(agent.clamp(0.0, 1.0));
    });
  }

  /// One-shot: emit `true` the first time we know the agent is in the room.
  void _markAgentReady(String why) {
    if (_agentReadyLatched) return;
    _agentReadyLatched = true;
    debugPrint('[voice] agent ready ($why)');
    if (!_agentReady.isClosed) _agentReady.add(true);
  }

  @override
  Stream<TranscriptSegment> get transcripts => _transcripts.stream;

  @override
  Stream<ToolUsedEvent> get toolEvents => _toolEvents.stream;

  @override
  Stream<String> get callEnding => _callEnding.stream;

  @override
  Stream<bool> get agentMute => _agentMute.stream;

  @override
  Stream<String> get practiceCoach => _practiceCoach.stream;

  @override
  Stream<String> get voiceStatus => _voiceStatus.stream;

  @override
  Stream<Object> get closed => _closed.stream;

  @override
  Future<void> connect({
    required String url,
    required String token,
    bool forceRelay = false,
  }) async {
    debugPrint('[voice] connect -> $url (token ${token.length} chars)'
        '${forceRelay ? ' [ice-relay-retry: TURN relay forced]' : ''}');
    final room = Room(
      roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
    );
    _room = room;
    final listener = room.createListener();
    _listener = listener;

    listener
      ..on<DataReceivedEvent>(_onData)
      ..on<RoomConnectedEvent>(
          (_) => debugPrint('[voice] RoomConnected'))
      ..on<ParticipantConnectedEvent>((e) => debugPrint(
          '[voice] participant joined: ${e.participant.identity}'))
      ..on<TrackSubscribedEvent>((e) {
        debugPrint(
            '[voice] track subscribed: ${e.track.kind} from ${e.participant.identity}');
        // First remote audio track = the agent is in the room and audible.
        if (e.track.kind == TrackType.AUDIO) {
          _markAgentReady('remote audio from ${e.participant.identity}');
        }
      })
      ..on<RoomReconnectingEvent>(
          (_) => debugPrint('[voice] reconnecting'))
      ..on<RoomDisconnectedEvent>((e) {
        debugPrint('[voice] RoomDisconnected: ${e.reason}');
        if (!_closed.isClosed) {
          _closed.add(e.reason ?? 'disconnected');
        }
      });

    try {
      await room.connect(
        url,
        token,
        // Default (null) lets ICE try everything (host/STUN/TURN candidates);
        // `relay` restricts it to LiveKit Cloud's TURN servers (TLS/443) for
        // networks where direct UDP never connects.
        connectOptions: forceRelay
            ? const ConnectOptions(
                rtcConfiguration: RTCConfiguration(
                  iceTransportPolicy: RTCIceTransportPolicy.relay,
                ),
              )
            : null,
      );
      debugPrint('[voice] room.connect returned ok'
          '${forceRelay ? ' (ice-relay-retry path)' : ''}');
    } catch (e, st) {
      debugPrint(
          '[voice] room.connect (forceRelay=$forceRelay) THREW: $e\n$st');
      rethrow;
    }

    _startLevelSampling();

    // Warm worker: the agent may already be in the room with an audio track
    // published, so no future TrackSubscribedEvent will fire — latch now.
    for (final p in room.remoteParticipants.values) {
      if (p.audioTrackPublications.isNotEmpty) {
        _markAgentReady('agent already in room: ${p.identity}');
        break;
      }
    }
  }

  void _onData(DataReceivedEvent e) {
    final topic = e.topic;
    try {
      final decoded = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
      if (topic == _userTranscriptTopic || topic == _agentTranscriptTopic) {
        if (_transcripts.isClosed) return;
        _transcripts.add(TranscriptSegment(
          topic: topic!,
          text: decoded['text'] as String? ?? '',
          isFinal: decoded['is_final'] as bool? ?? true,
        ));
      } else if (topic == _toolUsedTopic) {
        if (_toolEvents.isClosed) return;
        _toolEvents.add(ToolUsedEvent(
          name: decoded['name'] as String? ?? '',
          label: decoded['label'] as String? ?? '',
          phase: decoded['phase'] as String? ?? '',
        ));
      } else if (topic == _callEndingTopic) {
        if (_callEnding.isClosed) return;
        final reason = decoded['reason'] as String? ?? '';
        if (reason.isNotEmpty) _callEnding.add(reason);
      } else if (topic == _agentMuteTopic) {
        if (_agentMute.isClosed) return;
        _agentMute.add(decoded['muted'] == true);
      } else if (topic == _practiceCoachTopic) {
        if (_practiceCoach.isClosed) return;
        final isFinal = decoded['is_final'] as bool? ?? true;
        final text = decoded['text'] as String? ?? '';
        if (isFinal && text.isNotEmpty) _practiceCoach.add(text);
      } else if (topic == _voiceStatusTopic) {
        if (_voiceStatus.isClosed) return;
        final state = decoded['state'] as String? ?? '';
        if (state.isNotEmpty) _voiceStatus.add(state);
      } else if (topic == _agentStateTopic) {
        // Fallback readiness signal: the first agent_state message means the
        // agent's session is live even if its audio track hasn't subscribed yet.
        _markAgentReady('agent_state data message');
        // Authoritative speaking signal (§1.3). On barge-in the agent's native
        // turn-detection leaves `speaking`, so this flips false immediately —
        // the client's cue to stop treating agent audio as playing (§1.7 step
        // 10). The LiveKit SDK / server flush the actual jitter buffer.
        if (_agentSpeaking.isClosed) return;
        _agentSpeaking.add(decoded['state'] == 'speaking');
      }
    } catch (_) {
      // A malformed segment is dropped, not fatal to the session.
    }
  }

  @override
  Future<void> sendAgentMuteControl({required bool muted}) async {
    final participant = _room?.localParticipant;
    if (participant == null) {
      throw StateError('not connected to a voice room');
    }
    await participant.publishData(
      utf8.encode(jsonEncode({'muted': muted})),
      reliable: true,
      topic: _agentMuteControlTopic,
    );
  }

  @override
  Future<void> sendVoiceAccentControl({
    required String accent,
    required String language,
  }) async {
    final participant = _room?.localParticipant;
    if (participant == null) {
      throw StateError('not connected to a voice room');
    }
    await participant.publishData(
      utf8.encode(jsonEncode({'accent': accent, 'language': language})),
      reliable: true,
      topic: _voiceAccentControlTopic,
    );
  }

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    debugPrint('[voice] setMicrophoneEnabled($enabled)');
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(enabled);
      debugPrint('[voice] mic set ok');
    } catch (e, st) {
      debugPrint('[voice] setMicrophoneEnabled THREW: $e\n$st');
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _levelTimer?.cancel();
    _levelTimer = null;
    await _room?.disconnect();
  }

  @override
  Future<void> dispose() async {
    _levelTimer?.cancel();
    _levelTimer = null;
    await _listener?.dispose();
    await _room?.dispose();
    _room = null;
    _listener = null;
    if (!_agentReady.isClosed) await _agentReady.close();
    if (!_agentSpeaking.isClosed) await _agentSpeaking.close();
    if (!_transcripts.isClosed) await _transcripts.close();
    if (!_toolEvents.isClosed) await _toolEvents.close();
    if (!_callEnding.isClosed) await _callEnding.close();
    if (!_agentMute.isClosed) await _agentMute.close();
    if (!_practiceCoach.isClosed) await _practiceCoach.close();
    if (!_voiceStatus.isClosed) await _voiceStatus.close();
    if (!_closed.isClosed) await _closed.close();
    if (!_localLevel.isClosed) await _localLevel.close();
    if (!_agentLevel.isClosed) await _agentLevel.close();
  }
}
