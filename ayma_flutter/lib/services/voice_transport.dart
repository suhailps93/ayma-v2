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
  /// Emits `true` while a remote participant (the agent) is actively speaking.
  Stream<bool> get agentSpeaking;

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
  final _agentSpeaking = StreamController<bool>.broadcast();
  final _transcripts = StreamController<TranscriptSegment>.broadcast();
  final _closed = StreamController<Object>.broadcast();

  @override
  Stream<bool> get agentSpeaking => _agentSpeaking.stream;

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
      ..on<TrackSubscribedEvent>((e) => debugPrint(
          '[voice] track subscribed: ${e.track.kind} from ${e.participant.identity}'))
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
    await _room?.disconnect();
  }

  @override
  Future<void> dispose() async {
    await _listener?.dispose();
    await _room?.dispose();
    _room = null;
    _listener = null;
    if (!_agentSpeaking.isClosed) await _agentSpeaking.close();
    if (!_transcripts.isClosed) await _transcripts.close();
    if (!_closed.isClosed) await _closed.close();
  }
}
