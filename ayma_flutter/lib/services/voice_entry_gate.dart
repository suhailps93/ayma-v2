import 'connection_heartbeat.dart';

/// What a voice entry point should do with a call attempt, given the
/// connection heartbeat's current read (resilience chunk D — the degrade
/// glue between the connection heartbeat and voice).
enum VoiceEntryDecision {
  /// Start normally (direct route first, relay retry behind it).
  allow,

  /// Start on the forgiving TURN-relay route from the first attempt.
  allowRelayFirst,

  /// Do not attempt a live call at all — no route can succeed right now;
  /// the caller shows the offline note and offers chat / a voice message
  /// instead of burning a doomed connect + retry.
  denyOffline,
}

/// The single mapping every voice entry point (chat orb, nav-bar orb,
/// practice voice) consults before starting a session, so the degrade
/// behavior can never diverge between surfaces.
VoiceEntryDecision voiceEntryDecision(ConnectionQuality quality) =>
    switch (quality) {
      ConnectionQuality.ok => VoiceEntryDecision.allow,
      ConnectionQuality.weak => VoiceEntryDecision.allowRelayFirst,
      ConnectionQuality.offline => VoiceEntryDecision.denyOffline,
    };
