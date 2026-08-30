import 'dart:async';
import 'dart:convert';

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
    final room = Room(
      roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
    );
    _room = room;
    final listener = room.createListener();
    _listener = listener;

    listener
      ..on<ActiveSpeakersChangedEvent>((e) {
        final agentTalking = e.speakers.any((p) => p is RemoteParticipant);
        if (!_agentSpeaking.isClosed) _agentSpeaking.add(agentTalking);
      })
      ..on<DataReceivedEvent>(_onData)
      ..on<RoomDisconnectedEvent>((e) {
        if (!_closed.isClosed) {
          _closed.add(e.reason ?? 'disconnected');
        }
      });

    await room.connect(url, token);
  }

  void _onData(DataReceivedEvent e) {
    final topic = e.topic;
    if (topic != _userTranscriptTopic && topic != _agentTranscriptTopic) return;
    try {
      final decoded = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
      if (_transcripts.isClosed) return;
      _transcripts.add(TranscriptSegment(
        topic: topic!,
        text: decoded['text'] as String? ?? '',
        isFinal: decoded['is_final'] as bool? ?? true,
      ));
    } catch (_) {
      // A malformed segment is dropped, not fatal to the session.
    }
  }

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    await _room?.localParticipant?.setMicrophoneEnabled(enabled);
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
