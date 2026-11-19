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

/// A fully-populated "Taste match" payload (long strings so
/// the matrix stresses wrapping). Served for `/taste/pair` and embedded as the
/// match report's `taste` section.
Map<String, dynamic> _tastePayload() => {
  'source': 'fixture',
  'a': {'name': 'Sam'},
  'b': {'name': 'Maya'},
  'score': 72,
  'score_label': 'Strong overlap with a very long label to wrap',
  'summary': kLongText,
  'shared': [for (var i = 0; i < 6; i++) 'A long shared taste name $i'],
  'shared_tags': [
    for (var i = 0; i < 6; i++) 'A long why-you-match descriptor $i',
  ],
  'demographics': {
    'a': {'top_age': '24 & under'},
    'b': {'top_age': '45–54'},
    'note': 'Maya\'s tastes index 24 & under, while Leo\'s index much older '
        'at 45–54 — a wide age span worth a mention in the write-up.',
  },
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


/// A deliberately TALL Node-Visualiser tree (`…/tree` reads): a web-findings
/// "Facts" section of many long narrative nodes plus stat / confidence / link /
/// candidate nodes — the exact shape that overflowed the web-research report
/// (founder build 2488, "BOTTOM OVERFLOWED BY 466 PIXELS"). Served for every
/// report, shared-report and other-user graph tree read so the layout matrix
/// pumps real, scroll-length report content; a report body that is NOT wrapped
/// in a scroll view overflows here and fails the matrix.
List<Map<String, dynamic>> _factsSections() => [
  {
    'page_type': 'facts',
    'title': 'Facts',
    'order': 0,
    'nodes': [
      for (var i = 0; i < 12; i++)
        {
          'id': 'fact_$i',
          'section': 'facts',
          'label': 'Finding number $i found on the open web',
          'text': kLongText,
          'answer_type': 'narrative',
          'visibility': 'public',
          'subtree_visibility': 'public',
          'editable': true,
          'source_kind': 'web',
          'source_ref': 'https://example.com/finding/$i',
        },
      for (var i = 0; i < 3; i++)
        {
          'id': 'stat_$i',
          'section': 'facts',
          'label': 'A very long statistic label number $i that wraps across lines',
          'text': kLongText,
          'answer_type': 'stat',
          'stat_value': 7.5,
          'stat_text': '7.5',
          'stat_basis': kLongText,
          'visibility': 'public',
          'subtree_visibility': 'public',
          'editable': false,
        },
      {
        'id': 'confidence',
        'section': 'facts',
        'label': 'Overall confidence in these web findings, a long label to wrap',
        'text': 'Medium',
        'answer_type': 'stat',
        'stat_text': 'Medium',
        'visibility': 'public',
        'subtree_visibility': 'public',
      },
      for (var i = 0; i < 4; i++)
        {
          'id': 'link_$i',
          'section': 'facts',
          'label': 'A very long social or profile link label number $i that keeps going',
          'text': '',
          'answer_type': 'link',
          'link_url': 'https://example.com/a/very/long/path/that/keeps/going/$i',
          'link_platform': ['linkedin', 'github', 'youtube', ''][i],
          'visibility': 'public',
          'subtree_visibility': 'public',
        },
      // A pending reverse-image-search candidate — the deep-dive report wires
      // its "This is me" / "Not me" buttons, so the matrix exercises that row.
      {
        'id': 'cand_0',
        'section': 'facts',
        'label': '',
        'text': kLongText,
        'answer_type': 'candidate',
        'image_url': 'https://cdn/candidate0.jpg',
        'candidate_id': 'c0',
        'visibility': 'public',
        'subtree_visibility': 'public',
      },
    ],
  },
];

/// The appearance report node tree (`GET /report/appearance/{uid}/tree`) in the
/// shape `report_tree.report_node_tree` produces over
/// `report_adapters.appearance_blocks`: an Attributes section of standard
/// attribute nodes + a photo grid, and Face / Body sections each with a numeric
/// score stat, narrative text, and their source photos. Long strings and a
/// multi-photo carousel so the TEMPLATED layout is held to the overflow matrix.
Map<String, dynamic> _appearanceTree() {
  Map<String, dynamic> attr(String id, String label, String value) => {
    'id': id,
    'section': 'attributes',
    'label': label,
    'text': value,
    'answer_type': 'text',
    'level': 1,
    'visibility': 'public',
    'subtree_visibility': 'public',
    'standard': true,
    'standard_label': label,
  };
  Map<String, dynamic> stat(String id, String verdict, num value) => {
    'id': id,
    'section': id,
    'label': verdict,
    'text': verdict,
    'answer_type': 'stat',
    'level': 1,
    'visibility': 'public',
    'subtree_visibility': 'public',
    'stat_value': value,
    'stat_text': '$value',
    'stat_basis': 'A long basis line explaining the weighting of this score',
  };
  Map<String, dynamic> text(String id, String section) => {
    'id': id,
    'section': section,
    'label': '',
    'text': kLongText,
    'answer_type': 'text',
    'level': 1,
    'visibility': 'public',
    'subtree_visibility': 'public',
  };
  Map<String, dynamic> image(String id, String section) => {
    'id': id,
    'section': section,
    'label': '',
    'text': kLongText,
    'answer_type': 'image',
    'level': 1,
    'visibility': 'public',
    'subtree_visibility': 'public',
    'image_url': 'https://cdn/$id.jpg',
    'image_read': kLongText,
  };
  return {
    'surface': 'report',
    'title': 'Appearance',
    'sections': [
      {
        'page_type': 'attributes',
        'title': 'Attributes',
        'order': 0,
        'nodes': [
          attr('attr:eye_color', 'Eye color',
              'A long descriptive eye-colour value that should wrap on narrow'),
          attr('attr:hair_color', 'Hair color', 'Dark brown, wavy, mid-length'),
          attr('attr:build', 'Build', 'Athletic, broad-shouldered'),
          for (var i = 0; i < 3; i++) image('attr:photos:$i', 'attributes'),
        ],
      },
      {
        'page_type': 'face',
        'title': 'Face',
        'order': 1,
        'nodes': [
          stat('face', 'Striking', 7.8),
          text('face:note:sent:0', 'face'),
          image('face:photo', 'face'),
        ],
      },
      {
        'page_type': 'body',
        'title': 'Body',
        'order': 2,
        'nodes': [
          stat('body', 'Strong physique', 8.1),
          text('body:note:sent:0', 'body'),
          image('body:photo', 'body'),
        ],
      },
    ],
    'meta': {'owner_uid': 'me', 'viewer_can_edit': true},
  };
}


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
  if (path == '/appearance/eligibility') {
    // Populated Face and Body buckets so the matrix covers the pre-run sheet's
    // selectable thumbnails + the always-present Add photo tile (not just the
    // empty-group prompts).
    return {
      'face': [for (var i = 0; i < 3; i++) {'media_id': 'f$i', 'url': 'https://cdn/f$i.jpg'}],
      'body': [for (var i = 0; i < 3; i++) {'media_id': 'b$i', 'url': 'https://cdn/b$i.jpg'}],
      'has_face_photo': true,
      'has_body_photo': true,
    };
  }
  if (path == '/profile/bullets') {
    return {
      'sections': [
        for (var i = 0; i < 4; i++)
          {
            'page_type': 'section_$i',
            'title': 'Section $i $kLongName',
            'subtitle': kLongText,
            'order': i,
            'page_id': i == 3 ? '' : 'p$i',
            'bullets': i == 3
                ? []
                : [
                    {'id': 'b${i}0', 'text': kLongText, 'visibility': 'public'},
                    {'id': 'b${i}1', 'text': kLongText, 'visibility': 'private'},
                    {'id': 'b${i}2', 'text': kLongText, 'visibility': 'ai_only'},
                  ],
          },
      ],
      'visibilities': ['public', 'private', 'ai_only'],
    };
  }
  if (path.startsWith('/profile/graph/tree')) {
    // A Career section with a dated and an undated entry + long text, so the
    // matrix holds the Career section's rows (now a normal section inside Your
    // Story, no longer a dedicated view) at every viewport, scale and direction
    // — PLUS the tall web-findings Facts section so Your Story / public-profile
    // pump real scroll-length node content (a non-scrolling body would overflow
    // here, build 2488).
    return {
      'surface': path == '/profile/graph/tree' ? 'story' : 'public_profile',
      'sections': [
        ..._factsSections(),
        {
          'page_type': 'career',
          'title': 'Career',
          'order': 3,
          'nodes': [
            {
              'id': 'career.linkedin',
              'section': 'career',
              'label': 'LinkedIn',
              'text': 'LinkedIn',
              'answer_type': 'link',
              'link_url': 'https://www.linkedin.com/in/example',
              'link_platform': 'linkedin',
              'visibility': 'public',
              'subtree_visibility': 'public',
              'editable': false,
            },
            {
              'id': 'career_role_narrative',
              'section': 'career',
              'label': 'Role',
              'text': kLongText,
              'answer_type': 'narrative',
              'visibility': 'public',
              'subtree_visibility': 'public',
              'editable': true,
              'dated': '2021-06 — present',
            },
            {
              'id': 'education_level',
              'section': 'career',
              'label': 'Education',
              'text': kLongText,
              'answer_type': 'narrative',
              'visibility': 'private',
              'subtree_visibility': 'private',
              'editable': true,
            },
          ],
        },
      ],
    };
  }
  if (path == '/profile/graph') {
    return {
      'center': {'id': 'me', 'label': 'Me'},
      'nodes': [
        {'id': 'me', 'kind': 'person', 'label': 'Me'},
        for (var i = 0; i < 6; i++) ...[
          {'id': 's$i', 'kind': 'section', 'label': 'Section $i $kLongName', 'subtitle': kLongText, 'page_type': 'section_$i'},
          {'id': 'b$i', 'kind': 'bullet', 'text': kLongText, 'visibility': i.isEven ? 'public' : 'ai_only'},
        ],
      ],
      'edges': [
        for (var i = 0; i < 6; i++) ...[
          {'from': 'me', 'to': 's$i'},
          {'from': 's$i', 'to': 'b$i'},
        ],
      ],
    };
  }
  if (path == '/explore') {
    return {'cards': [for (var i = 0; i < 6; i++) _card(i)]};
  }
  if (path.startsWith('/explore/profile/')) return _profile();
  if (path == '/profiles/mini') {
    // Names + photos for the "send to a user" recipient picker. Long name so
    // the row's name ellipsizes rather than overflowing next to the avatar
    // and Send button at scale 2.0.
    return {
      'profiles': {
        'her': {'name': kLongName, 'photo': 'https://cdn/her.jpg', 'online': true},
        'bob': {'name': 'Bob', 'photo': '', 'online': false},
      },
    };
  }
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
  if (path == '/brain/preference') {
    return {
      'brains': [
        {
          'id': 'gemini',
          'label': 'Gemini',
          'description':
              'Google Gemini — reads images, does live web research, and uses '
                  'tools. The most capable all-round brain.',
          'available': true,
          'capabilities': ['text', 'json', 'vision', 'web', 'tools'],
        },
        {
          'id': 'meta',
          'label': 'Meta Muse Spark',
          'description':
              'Meta’s Muse Spark — fast reasoning for chat, matching and '
                  'coaching. Image reading and web research fall back to Gemini.',
          'available': true,
          'capabilities': ['text', 'json', 'tools'],
        },
      ],
      'current': '',
      'default': 'meta',
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
          'supports_accent': true,
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
  if (path.startsWith('/match/')) {
    // The match report carries the embedded "Taste match"
    // section so the matrix exercises it on the match-report route.
    return {..._report(), 'taste': {..._tastePayload(), 'status': 'ok'}};
  }

  if (path.startsWith('/report/appearance/') && path.endsWith('/tree')) {
    // The APPEARANCE report's TEMPLATED page (score header, carousel-style
    // photos, attribute fields) renders from this node tree — give the matrix a
    // populated attributes/face/body tree with long strings so every section,
    // the carousel and the score header are held to the overflow bars.
    return _appearanceTree();
  }

  // A report / shared-report as a Node-Visualiser TREE (`…/tree`): the tall
  // web-findings Facts tree so the matrix pumps full-length report content
  // (deep_dive / match / story_ai_notes / shared - appearance is
  // handled by the branch above). Must precede
  // the living-report block shape below, which `/report/` also matches.
  if (path.endsWith('/tree') &&
      (path.startsWith('/report/') || path.startsWith('/s/'))) {
    return {'surface': 'report', 'sections': _factsSections()};

  }
  if (path.startsWith('/report/') ||
      path.startsWith('/deep-dive-report/') ||
      path.startsWith('/skills/report/') ||
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
  if (path.startsWith('/p/')) {
    return {
      'kind': 'profile',
      'target_id': 'her',
      'title': kLongName,
      'summary': kLongText,
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
    return _tastePayload();
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

/// Like [layoutApi] but the report reads 404 — the server's "never run"
/// signal. Drives the web-research screen's "No web research yet" empty
/// state (not the "Couldn't load" error) for the layout matrix.
ApiClient layoutApi404() => ApiClient(
  httpClient: MockClient((request) async {
    final path = request.url.path;
    if (path.contains('/report/') || path.contains('/deep-dive-report/')) {
      return http.Response(
        jsonEncode({'detail': 'No such report.'}),
        404,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response(
      jsonEncode(_bodyFor(path)),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }),
  auth: kLayoutAuth,
);

/// Like [layoutApi] but `/appearance/eligibility` returns NO analysable photos
/// while flagging `has_unconfirmed_photos` — the demo-test1 / NOTE 263 state
/// (the user has photos but none are confirmed as them). Drives the pre-run
/// sheet's honest confirm-a-photo blocked banner + disabled Run button for the
/// layout matrix.
ApiClient layoutApiAppearanceUnconfirmed() => ApiClient(
  httpClient: MockClient((request) async {
    if (request.url.path == '/appearance/eligibility') {
      return http.Response(
        jsonEncode({
          'face': <dynamic>[],
          'body': <dynamic>[],
          'has_face_photo': false,
          'has_body_photo': false,
          'has_unconfirmed_photos': true,
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response(
      jsonEncode(_bodyFor(request.url.path)),
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
