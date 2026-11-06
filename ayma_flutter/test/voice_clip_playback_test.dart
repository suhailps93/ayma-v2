import 'dart:async';

import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_clip_playback.dart';
import 'package:ayma_flutter/services/voice_clip_registry.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// A clip whose playback state the test flips by hand.
class _FakeClip {
  _FakeClip({
    required this.key,
    required this.owner,
    required this.order,
    this.label = 'your voice message',
    this.failStart = false,
    required this.events,
  });

  final String key;
  final String owner;
  final int order;
  final String label;
  final bool failStart;
  final List<String> events;
  bool playing = false;

  VoiceClipHandle get handle => VoiceClipHandle(
        key: key,
        owner: owner,
        label: label,
        order: order,
        start: () async {
          events.add('play:$key');
          if (failStart) throw StateError('no player');
          playing = true;
        },
        isPlaying: () => playing,
        stop: () async {
          events.add('stop-clip:$key');
          playing = false;
        },
      );
}

/// A voice session that records the disconnect/reconnect sequence
/// instead of touching LiveKit.
class _FakeSession extends VoiceSessionController {
  _FakeSession(this.events) : super(transcriptStore: TranscriptStore());

  final List<String> events;
  bool live = true;
  String noted = '';

  @override
  bool get isActive => live;

  @override
  Future<void> stop() async {
    events.add('disconnect');
    live = false;
  }

  @override
  Future<void> start({bool forceRelayFirst = false}) async {
    events.add('reconnect');
    live = true;
  }

  @override
  void noteResumeContext(String note) {
    events.add('note');
    noted = note;
  }
}

VoiceClipPlayback _playback({
  required VoiceSessionController? session,
}) {
  return VoiceClipPlayback(
    activeSession: () => session,
    announceGrace: Duration.zero,
    pollInterval: const Duration(milliseconds: 5),
    startWait: const Duration(milliseconds: 50),
  );
}

void main() {
  group('VoiceClipRegistry.resolve', () {
    VoiceClipRegistry registryWith(List<_FakeClip> clips) {
      final reg = VoiceClipRegistry();
      reg.sync(Object(), [for (final c in clips) c.handle]);
      return reg;
    }

    final events = <String>[];
    _FakeClip clip(String key, String owner, int order) => _FakeClip(
        key: key, owner: owner, order: order, events: events);

    test('latest, previous, mine and ayma pick the right clip', () {
      final reg = registryWith([
        clip('u1', 'user', 0),
        clip('a1', 'ayma', 1),
        clip('u2', 'user', 2),
      ]);
      expect(reg.resolve('')?.key, 'u2');
      expect(reg.resolve('latest')?.key, 'u2');
      expect(reg.resolve('previous')?.key, 'a1');
      expect(reg.resolve('mine')?.key, 'u2');
      expect(reg.resolve('ayma')?.key, 'a1');
      expect(reg.resolve('hers')?.key, 'a1');
      expect(reg.resolve('a1')?.key, 'a1');
    });

    test('no clips, or no clip of that owner, resolves to null', () {
      expect(VoiceClipRegistry().resolve('latest'), isNull);
      final reg = registryWith([clip('a1', 'ayma', 0)]);
      expect(reg.resolve('mine'), isNull);
      expect(reg.resolve('previous'), isNull);
    });

    test('clearing a surface withdraws its clips', () {
      final token = Object();
      final reg = VoiceClipRegistry();
      reg.sync(token, [clip('u1', 'user', 0).handle]);
      expect(reg.clips, hasLength(1));
      reg.clear(token);
      expect(reg.clips, isEmpty);
    });
  });

  group('VoiceClipPlayback', () {
    test('no live session: the clip simply plays', () async {
      final events = <String>[];
      final clip = _FakeClip(key: 'u1', owner: 'user', order: 0, events: events);
      final run = _playback(session: null).begin(clip.handle);
      final started = await run.started;
      expect(started.ok, isTrue);
      expect(started.voicePaused, isFalse);
      expect(events, ['play:u1']);
      clip.playing = false;
      await run.done;
      expect(events, ['play:u1']); // nothing else was touched
    });

    test('live session: note, disconnect, play, reconnect — in order',
        () async {
      final events = <String>[];
      final session = _FakeSession(events);
      final clip = _FakeClip(
        key: 'a1',
        owner: 'ayma',
        order: 0,
        label: "Ayma's voice message",
        events: events,
      );
      final run = _playback(session: session).begin(clip.handle);
      final started = await run.started;
      expect(started.ok, isTrue);
      expect(started.voicePaused, isTrue);
      expect(events, ['note', 'disconnect', 'play:a1']);
      expect(session.noted, contains('disconnected'));
      expect(session.noted, contains("Ayma's voice message"));
      // The clip is still playing: no reconnect yet.
      expect(session.live, isFalse);
      clip.playing = false;
      await run.done;
      expect(events, ['note', 'disconnect', 'play:a1', 'reconnect']);
      expect(session.live, isTrue);
    });

    test('a clip that fails to start still reconnects the session',
        () async {
      final events = <String>[];
      final session = _FakeSession(events);
      final clip = _FakeClip(
          key: 'u1', owner: 'user', order: 0, failStart: true, events: events);
      final run = _playback(session: session).begin(clip.handle);
      final started = await run.started;
      expect(started.ok, isFalse);
      await run.done;
      expect(events, contains('reconnect'));
      expect(session.live, isTrue);
    });

    test('an inactive session is treated as no session', () async {
      final events = <String>[];
      final session = _FakeSession(events)..live = false;
      final clip = _FakeClip(key: 'u1', owner: 'user', order: 0, events: events);
      final run = _playback(session: session).begin(clip.handle);
      final started = await run.started;
      expect(started.ok, isTrue);
      expect(started.voicePaused, isFalse);
      expect(events, ['play:u1']);
      clip.playing = false;
      await run.done;
    });
  });

  group('AppCommandService play_voice_clip', () {
    test('plays the resolved clip and reports what is playing', () async {
      final events = <String>[];
      final clip = _FakeClip(key: 'u1', owner: 'user', order: 0, events: events);
      final registry = VoiceClipRegistry()
        ..sync(Object(), [clip.handle]);
      final svc = AppCommandService(
        clipRegistry: registry,
        clipPlayback: _playback(session: null),
      );
      final out = await svc.runPlayVoiceClip({'which': 'latest'});
      expect(out.ok, isTrue);
      expect(out.message, contains('your voice message'));
      expect(events, ['play:u1']);
      clip.playing = false;
    });

    test('no clip in the chat is an honest failure, never a throw',
        () async {
      final svc = AppCommandService(
        clipRegistry: VoiceClipRegistry(),
        clipPlayback: _playback(session: null),
      );
      final out = await svc.runPlayVoiceClip({'which': 'latest'});
      expect(out.ok, isFalse);
      expect(out.message, contains('no voice clip'));
    });
  });
}
