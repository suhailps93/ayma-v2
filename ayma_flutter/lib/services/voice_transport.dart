import 'dart:async';

import 'package:livekit_client/livekit_client.dart';

/// Narrow seam over the LiveKit room so [VoiceSessionController] and its tests
/// never touch `livekit_client` directly (ARCHITECTURE.md §1.7 step 5).
///
/// Step 14 needs only: join a room, publish the mic, hear the agent, mute,
/// leave. Transcript data-channel events (§1.6) are Step 15.
abstract class VoiceTransport {
  /// Emits `true` while a remote participant (the agent) is actively speaking.
  Stream<bool> get agentSpeaking;

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
  final _closed = StreamController<Object>.broadcast();

  @override
  Stream<bool> get agentSpeaking => _agentSpeaking.stream;

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
      ..on<RoomDisconnectedEvent>((e) {
        if (!_closed.isClosed) {
          _closed.add(e.reason ?? 'disconnected');
        }
      });

    await room.connect(url, token);
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
    if (!_closed.isClosed) await _closed.close();
  }
}
