import 'package:ayma_flutter/services/wiki_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, dynamic>> _rows() => [
      {
        'id': 'career',
        'page_type': 'career',
        'visibility': 'private',
        'ai_body': 'Works as a teacher.',
      },
      {
        'id': 'sailing',
        'page_type': 'interests',
        'visibility': 'public',
        'ai_body': 'Sails on weekends.',
      },
      {
        'id': 'therapy',
        'page_type': 'sensitive',
        'visibility': 'ai_only',
        'ai_body': 'In weekly therapy.',
      },
      {
        // Legacy hide flag on a private page — the private view now ignores it.
        'id': 'hidden-thing',
        'page_type': 'misc',
        'visibility': 'private',
        'ai_body': 'Was hidden; should reappear.',
        'user_hidden': true,
      },
      {
        // Legacy hide flag on a public page — the public view still honours it.
        'id': 'hidden-public',
        'page_type': 'misc',
        'visibility': 'public',
        'ai_body': 'Pulled off the public profile once.',
        'user_hidden': true,
      },
      {
        'id': 'values',
        'page_type': 'values',
        'visibility': 'private',
        'ai_body': 'AI wrote this.',
        'user_edits': 'But the user rewrote it.',
      },
    ];

void main() {
  test('private view = public + private, no ai_only, legacy hidden reappears',
      () {
    final pages = WikiService.filterPages(
        _rows(), const {'public', 'private'},
        honorHidden: false);
    final ids = pages.map((p) => p.pageId).toList();

    expect(ids, containsAll(['career', 'sailing', 'values', 'hidden-thing']));
    expect(ids, isNot(contains('therapy'))); // ai_only never surfaces
  });

  test('public view = public pages only, still honours a legacy hide', () {
    final pages = WikiService.filterPages(_rows(), const {'public'});
    expect(pages.map((p) => p.pageId), ['sailing']);
  });

  test('user_edits overrides ai_body', () {
    final pages =
        WikiService.filterPages(_rows(), const {'public', 'private'});
    final values = pages.firstWhere((p) => p.pageId == 'values');
    expect(values.body, 'But the user rewrote it.');
  });

  test('view carries each page visibility', () {
    final pages =
        WikiService.filterPages(_rows(), const {'public', 'private'});
    expect(pages.firstWhere((p) => p.pageId == 'career').isPublic, isFalse);
    expect(pages.firstWhere((p) => p.pageId == 'sailing').isPublic, isTrue);
  });

  test('sorted by (page_type, page_id)', () {
    final pages =
        WikiService.filterPages(_rows(), const {'public', 'private'});
    expect(pages.map((p) => p.pageType).toList(),
        ['career', 'interests', 'values']);
  });

  test('blank bodies are dropped', () {
    final pages = WikiService.filterPages([
      {'id': 'x', 'visibility': 'private', 'ai_body': '   '},
    ], const {'private'});
    expect(pages, isEmpty);
  });

  group('edit payloads never touch ai_body', () {
    test('editPayload sets user_edits and clears user_hidden', () {
      final p = WikiService.editPayload('  my version  ');
      expect(p['user_edits'], 'my version');
      expect(p['user_hidden'], false);
      expect(p.containsKey('ai_body'), isFalse);
      expect(p['user_updated_at'], isA<FieldValue>());
    });

    test('resetPayload deletes the override fields', () {
      final p = WikiService.resetPayload();
      expect(p['user_edits'], isA<FieldValue>());
      expect(p['user_hidden'], isA<FieldValue>());
      expect(p.containsKey('ai_body'), isFalse);
    });

    test('visibilityPayload sets only visibility + timestamp', () {
      final p = WikiService.visibilityPayload('public');
      expect(p['visibility'], 'public');
      expect(p['user_updated_at'], isA<FieldValue>());
      expect(p.containsKey('ai_body'), isFalse);
      expect(p.containsKey('user_edits'), isFalse);
    });
  });
}
