import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// APP ACTION GRAPH coverage sanity, client side (ACTION PARITY,
/// founder 2026-11-06): the graph doc names the client command surface
/// and the exclusions; the registry carries the exclusions config.
/// The backend mirror of these checks lives in
/// `functions/bootstrap/tests/test_app_action_graph.py`.
Map<String, dynamic> _registry() => jsonDecode(
        File('../functions/bootstrap/app_registry.json').readAsStringSync())
    as Map<String, dynamic>;

String _graph() =>
    File('../docs/APP_ACTION_GRAPH.md').readAsStringSync();

void main() {
  test('the graph covers every client command action', () {
    final graph = _graph();
    // Every `action` value AppCommandService dispatches, plus the
    // app_action names it executes — each must be named in the graph.
    for (final name in [
      'navigate',
      'search_explore',
      'open_profile',
      'open_dm_thread',
      'open_notification',
      'app_action',
      'reconnect_voice',
      'ui_action',
      'tour_step',
      'tour_end',
      'play_voice_clip',
      'dark_mode',
      'light_mode',
      'system_theme',
      'accent_color',
      'pause_matching',
      'resume_matching',
      'sign_out',
    ]) {
      expect(graph, contains(name), reason: '$name missing from the graph');
    }
  });

  test('exclusions config lists exactly the founder-ruled controls', () {
    final exclusions = _registry()['exclusions'] as Map<String, dynamic>;
    final items = (exclusions['items'] as List).cast<Map<String, dynamic>>();
    expect(items.map((e) => e['key']).toSet(), {
      'delete_account',
      'purchase',
      'clear_memory',
      'delete_photo_everywhere',
      'block_report',
      'dismiss_all_suggestions',
    });
    for (final item in items) {
      expect((item['via'] as String).trim(), isNotEmpty, reason: '$item');
    }
    // Clear memory is navigate-only in the account actions, never a
    // handler Ayma can run.
    final acts = (_registry()['account_actions'] as List)
        .cast<Map<String, dynamic>>();
    final wipe = acts.singleWhere((a) => a['key'] == 'wipe_memory');
    expect(wipe['handler'], 'navigate_only');
    expect(wipe['destination'], 'ayma_settings');
    // And the graph marks them EXCLUDED.
    final graph = _graph();
    expect(graph, contains('EXCLUDED'));
    expect(graph, contains('Delete account'));
    expect(graph, contains('Clear Ayma memory'));
  });

  test('voice_clip_playback registry block names the wired command', () {
    final block =
        _registry()['voice_clip_playback'] as Map<String, dynamic>;
    expect(block['operated_by_ayma'], isTrue);
    expect(block['command'], 'play_voice_clip');
    expect(block['client_action'], 'play_voice_clip');
    expect(_graph(), contains('play_voice_clip'));
  });
}
