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

const _userTranscriptTopic = 'user_transcript';
const _agentTranscriptTopic = 'agent_transcript';
const _agentStateTopic = 'agent_state';

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

  /// Emits once if the transport drops unexpectedly (network / server close).
  Stream<Object> get closed;

  Future<void> connect({required String url, required String token});

  Future<void> setMicrophoneEnabled(bool enabled);

  Future<void> disconnect();

  Future<void> dispose();
}

/// Real transport backed by a LiveKit [Room].
class LiveKitVoiceTransport implements VoiceTransport {
  LiveKitVoiceTransport();

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  Timer? _levelTimer;
  final _agentReady = StreamController<bool>.broadcast();
  final _agentSpeaking = StreamController<bool>.broadcast();
  final _transcripts = StreamController<TranscriptSegment>.broadcast();
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
  Stream<Object> get closed => _closed.stream;

  @override
  Future<void> connect({required String url, required String token}) async {
    debugPrint('[voice] connect -> $url (token ${token.length} chars)');
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
      await room.connect(url, token);
      debugPrint('[voice] room.connect returned ok');
    } catch (e, st) {
      debugPrint('[voice] room.connect THREW: $e\n$st');
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
    if (!_closed.isClosed) await _closed.close();
    if (!_localLevel.isClosed) await _localLevel.close();
    if (!_agentLevel.isClosed) await _agentLevel.close();
  }
}
