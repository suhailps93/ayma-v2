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
        'id': 'hidden-thing',
        'page_type': 'misc',
        'visibility': 'private',
        'ai_body': 'Should not show.',
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
  test('private view = public + private, no ai_only, no user_hidden', () {
    final pages =
        WikiService.filterPages(_rows(), const {'public', 'private'});
    final ids = pages.map((p) => p.pageId).toList();

    expect(ids, containsAll(['career', 'sailing', 'values']));
    expect(ids, isNot(contains('therapy'))); // ai_only
    expect(ids, isNot(contains('hidden-thing'))); // user_hidden
  });

  test('public view = public pages only', () {
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

    test('hidePayload only sets user_hidden', () {
      final p = WikiService.hidePayload();
      expect(p['user_hidden'], true);
      expect(p.containsKey('ai_body'), isFalse);
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
