import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/mcp_connect_service.dart';
import 'package:ayma_flutter/services/revenuecat_service.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Deliberately long user-facing strings, so the matrix proves names, titles
/// and chips wrap or ellipsize instead of overflowing.
const kLongName = 'Maximiliana Alexandrina Montgomery-Featherstonehaugh';
const kLongText =
    'Grew up between Lisbon and Reykjavik, studied computational linguistics, '
    'now restores vintage synthesizers and runs ultramarathons on weekends. '
    'Looking for someone curious, kind and endlessly patient with detours.';

final MockFirebaseAuth kLayoutAuth = MockFirebaseAuth(
  signedIn: true,
  mockUser: MockUser(uid: 'me', email: 'me@example.com', displayName: kLongName),
);

Map<String, dynamic> _card(int i) => {
  'uid': 'u$i',
  'name': '$kLongName $i',
  'age': 29 + i,
  'location': 'San Francisco Bay Area, California, United States',
  'photo_url': '',
  'photos': <String>[],
  'headline': kLongText,
  'score': 0.87,
  'tags': [
    for (final t in [
      'Rock climbing',
      'Analog synthesizers',
      'Ultramarathons',
      'Portuguese cooking',
      'Philosophy of mind',
      'Jazz piano',
    ])
      t,
  ],
};

List<Map<String, dynamic>> _pages() => [
  for (final t in [
    'identity',
    'career',
    'interests',
    'personality',
    'values',
    'goals',
  ])
    {'page_type': t, 'title': 'A very long section title for $t', 'body': kLongText},
];

Map<String, dynamic> _profile() => {
  'uid': 'her',
  'self': false,
  'blocked': false,
  'name': kLongName,
  'age': 30,
  'location': 'San Francisco Bay Area, California, United States',
  'photos': <String>[],
  'pages': _pages(),
  'liked': false,
  'score': 0.91,
  'thread_id': 'her__me',
  'has_chatted': true,
  'deep_dive_id': '',
};

Map<String, dynamic> _report() => {
  'title': 'Report on $kLongName',
  'subject_name': kLongName,
  'status': 'ready',
  'blocks': [
    for (var i = 0; i < 6; i++)
      {
        'id': 'b$i',
        'type': i.isEven ? 'text' : 'score',
        'label': 'A long block label number $i that keeps going',
        'title': 'A long block title number $i that keeps going',
        'text': kLongText,
        'body': kLongText,
        'score': 0.7,
        'value': 7,
        'chips': ['Rock climbing', 'Analog synthesizers', 'Ultramarathons'],
      },
  ],
  // The living-report shape (`/report/{type}/{id}`, shared reports): every
  // block type, with long labels, values and chips.
  'sections': [
    for (var i = 0; i < 3; i++)
      {
        'heading': 'A long section heading number $i that keeps going on',
        'blocks': [
          {'block_id': 's${i}h', 'type': 'section_head', 'text': kLongText},
          {'block_id': 's${i}t', 'type': 'text', 'text': kLongText, 'editable': true},
          {
            'block_id': 's${i}f',
            'type': 'fact',
            'text': kLongText,
            'tag': 'A long tag label',
            'confidence': 'high',
            'source': 'Conversation with Ayma on a long-named date',
          },
          {
            'block_id': 's${i}a',
            'type': 'attribute',
            'label': 'A very long attribute label that wraps',
            'value': 'An equally long attribute value that also wraps around',
            'basis': kLongText,
          },
          {
            'block_id': 's${i}s',
            'type': 'stat',
            'label': 'A very long statistic label',
            'value': 9876543,
          },
          {
            'block_id': 's${i}l',
            'type': 'link',
            'label': 'A very long link label that keeps going and going',
            'url': 'https://example.com/a/very/long/path/that/keeps/going',
          },
          {
            'block_id': 's${i}p',
            'type': 'photo_grid',
            'photos': [
              for (var j = 0; j < 5; j++) {'url': '', 'caption': kLongText},
            ],
          },
        ],
      },
  ],
  'meta': {'owner_uid': 'me', 'viewer_can_edit': true},
};

Object? _bodyFor(String path) {
  if (path == '/dm/assist') {
    // Coach mode with the longest plausible chips + tip, so the matrix holds
    // the suggestion bar and the tip row to every viewport/scale/RTL variant.
    return {
      'mode': 'coach',
      'chips': [for (var i = 0; i < 4; i++) '$kLongText (chip $i)'],
      'tip': kLongText,
    };
  }
  if (path == '/explore') {
    return {'cards': [for (var i = 0; i < 6; i++) _card(i)]};
  }
  if (path.startsWith('/explore/profile/')) return _profile();
  if (path == '/chat/history') {
    return {
      'messages': [
        for (var i = 0; i < 6; i++)
          {
            'role': i.isEven ? 'user' : 'model',
            'text': kLongText,
            'timestamp': '2026-10-2${i}T10:00:00Z',
          },
      ],
      'next_before': null,
    };
  }
  if (path == '/voice/presets') {
    return {
      'presets': [
        for (final n in ['Aoede', 'Kore', 'Puck', 'Charon'])
          {'name': n, 'label': '$n, a long descriptive voice label', 'gender': 'f'},
      ],
    };
  }
  if (path == '/voice/engines') {
    final gemVoices = [
      for (final n in ['Aoede', 'Kore', 'Puck', 'Charon'])
        {'id': n, 'label': n, 'description': 'a long descriptive voice character'},
    ];
    final ttsVoices = [
      {'id': '', 'label': 'Default voice'},
      {'id': 'Ashley', 'label': 'Ashley', 'description': 'warm and bright voice'},
      {'id': 'Hades', 'label': 'Hades', 'description': 'deep and intense voice'},
    ];
    final langs = [
      {'code': '', 'label': 'Default (English)'},
      {'code': 'ml-IN', 'label': 'Malayalam'},
      {'code': 'es-ES', 'label': 'Spanish'},
    ];
    return {
      'modes': ['realtime', 'cascade'],
      'source': 'livekit',
      'realtime_models': [
        {
          'id': 'gemini-live',
          'label': 'Gemini Live (native audio)',
          'provider': 'gemini',
          'available': true,
          'requires_secret': '',
          'voices': gemVoices,
          'languages': langs,
        },
        {
          'id': 'openai-realtime',
          'label': 'OpenAI Realtime',
          'provider': 'openai',
          'available': true,
          'requires_secret': 'OPENAI_API_KEY',
          'voices': [
            {'id': 'alloy', 'label': 'Alloy'},
          ],
          'languages': langs,
        },
      ],
      'brains': [
        {'id': 'meta-muse-spark', 'label': 'Meta Muse Spark', 'provider': 'meta', 'available': true},
        {'id': 'google/gemini-3.7-flash', 'label': 'google/gemini-3.7-flash', 'provider': 'google', 'available': true},
      ],
      'stt': [
        {'id': 'deepgram/nova-3', 'label': 'deepgram/nova-3', 'provider': 'deepgram', 'available': true},
      ],
      'tts': [
        {
          'id': 'inworld/inworld-tts-1',
          'label': 'inworld/inworld-tts-1',
          'provider': 'inworld',
          'available': true,
          'voices': ttsVoices,
          'languages': langs,
        },
      ],
      'default': {
        'mode': 'realtime',
        'realtime_model_id': 'gemini-live',
        'brain_id': 'meta-muse-spark',
        'stt_id': 'deepgram/nova-3',
        'tts_id': 'inworld/inworld-tts-1',
      },
      'current': {
        'mode': 'realtime',
        'realtime_model_id': 'gemini-live',
        'brain_id': 'meta-muse-spark',
        'stt_id': 'deepgram/nova-3',
        'tts_id': 'inworld/inworld-tts-1',
        'voice_id': 'Aoede',
        'language_code': '',
      },
    };
  }
  if (path.startsWith('/report/') ||
      path.startsWith('/deep-dive-report/') ||
      path.startsWith('/skills/report/') ||
      path.startsWith('/match/') ||
      path.startsWith('/s/') ||
      path == '/appearance/report' ||
      path == '/body-report' ||
      path == '/face-report' ||
      path == '/physical-attributes') {
    return _report();
  }
  if (path.startsWith('/physical-attributes-report/')) {
    return {
      'id': 'r1',
      'summary': kLongText,
      'photo_count': 4,
      'created_at': '2026-10-20T10:00:00Z',
      'fields': {
        for (final f in ['eye_color', 'hair_color', 'build', 'distinguishing_features'])
          f: {
            'value': 'A long descriptive value for $f that wraps',
            'source': 'photos',
            'confidence': 'high',
          },
      },
    };
  }
  if (path == '/profile/proposals') {
    return {
      'proposals': [
        {
          'page_id': 'interests',
          'title': 'Interests and hobbies',
          'changes': [
            {'id': 'c0', 'op': 'remove', 'text': kLongText},
            {'id': 'c1', 'op': 'add', 'text': kLongText},
          ],
        },
        {
          'page_id': 'career',
          'title': 'Career',
          'changes': [
            {'id': 'c0', 'op': 'add', 'text': kLongText},
          ],
        },
      ],
    };
  }
  if (path == '/admin/feedback') {
    return {
      'feedback': [
        for (var i = 0; i < 4; i++)
          {
            'id': 'f$i',
            'uid': 'a-very-long-user-identifier-$i',
            'source': i.isEven ? 'chat_card' : 'settings_form',
            'kind': i.isEven ? 'bug' : 'feature',
            'title': 'A long feedback title that should wrap on narrow $i',
            'body': kLongText,
            'screenshot_paths': i.isEven
                ? ['uploads/a/feedback_$i.png']
                : const <String>[],
            'screen': 'messages',
            'app_version': '1.30.0',
            'platform': 'android',
            'status': ['new', 'triaged', 'done'][i % 3],
            'created_at': '2026-10-2${i}T10:00:00Z',
          },
      ],
    };
  }
  if (path == '/admin/feedback/media') {
    return {'path': 'uploads/a/feedback_0.png', 'url': ''};
  }
  if (path == '/taste/pair') {
    return {
      'source': 'fixture',
      'a': {'name': 'Sam'},
      'b': {'name': 'Maya'},
      'score': 72,
      'score_label': 'Strong overlap with a very long label to wrap',
      'summary': kLongText,
      'shared': [for (var i = 0; i < 6; i++) 'A long shared taste name $i'],
      'domains': [
        {'domain': 'music', 'score': 72},
        {'domain': 'film', 'score': 64},
        {'domain': 'dining', 'score': 81},
      ],
      'date_ideas': [
        for (var i = 0; i < 3; i++)
          {
            'name': 'A very long venue name for the date idea $i',
            'kind': 'dining',
            'why': kLongText,
            'address': i.isEven ? '1234 Some Very Long Street Name, City' : null,
          },
      ],
    };
  }
  if (path == '/usage') {
    return {
      'total': 33000,
      'features': {'chat': 30000, 'matching': 3000},
      'credits': {'grant': 100, 'added': 0, 'used': 42, 'remaining': 58},
      'plan': 'free',
      'period_end': null,
      'tokens_per_credit': 1000,
      'is_dev': true,
    };
  }
  return <String, dynamic>{};
}

/// One fake backend for every screen in the matrix: plausible, long-string
/// JSON for the endpoints whose content drives layout, `{}` for the rest
/// (every parser in `ApiClient` tolerates missing fields).
ApiClient layoutApi() => ApiClient(
  httpClient: MockClient((request) async {
    final body = _bodyFor(request.url.path);
    return http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }),
  auth: kLayoutAuth,
);

/// A fake "Connect an agent" service: no network, no connected agents.
McpConnectService layoutMcpConnect() => McpConnectService(
  client: MockClient((request) async => http.Response(
    '{"connections": []}',
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  )),
  auth: kLayoutAuth,
);

/// A voice controller that never connects (no LiveKit, no network).
class LayoutFakeVoice extends VoiceSessionController {
  /// [quiet]: a live call where Ayma was told to "shut up" (the quiet chip
  /// and the quiet nav-bar orb are on screen).
  LayoutFakeVoice({this.quiet = false})
      : super(transcriptStore: TranscriptStore());

  final bool quiet;

  @override
  VoiceSessionPhase get phase =>
      quiet ? VoiceSessionPhase.live : VoiceSessionPhase.idle;

  @override
  bool get isActive => quiet;

  @override
  bool get isListening => quiet;

  @override
  bool get aymaQuiet => quiet;
}

/// A store that is configured but has no subscription or trial: the Plan
/// page and paywalls render their full, purchasable layout.
class LayoutFakeRc extends RevenueCatService {
  @override
  bool get enabled => true;

  @override
  Future<List<PlanOption>> plans() async => RevenueCatService.fallbackPlans;

  @override
  Future<TrialOffer?> proTrialOffer() async => null;

  @override
  Future<ActiveSubscription?> activeSubscription() async => null;
}

/// Firestore content for the screens that read it directly: a scored match
/// with someone, a DM thread full of long messages, and notifications.
Future<FakeFirebaseFirestore> layoutFirestore() async {
  final fs = FakeFirebaseFirestore();
  final at = Timestamp.fromDate(DateTime(2026, 10, 20, 10));
  await fs.doc('users/her/profile/main').set({'name': kLongName});
  await fs.doc('matches/m1').set({
    'uids': ['me', 'her'],
    'status': 'scored',
    'score': 0.91,
    'user_explanation': {'me': kLongText},
  });
  await fs.doc('dm_threads/her__me').set({
    'participants': ['me', 'her'],
    'last_message_at': at,
    'unread': {'me': 3},
  });
  for (var i = 0; i < 8; i++) {
    await fs.collection('dm_threads/her__me/messages').add({
      'sender_uid': i.isEven ? 'me' : 'her',
      'type': 'text',
      'body': kLongText,
      'created_at': Timestamp.fromDate(DateTime(2026, 10, 20, 10, i)),
    });
  }
  for (var i = 0; i < 4; i++) {
    await fs.collection('users/me/notifications').add({
      'type': 'match',
      'title': 'A long notification title about $kLongName',
      'body': kLongText,
      'deep_link': '/match-request/m1',
      'read': i.isEven,
      'created_at': at,
    });
  }
  return fs;
}
