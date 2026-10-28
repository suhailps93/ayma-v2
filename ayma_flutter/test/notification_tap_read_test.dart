import 'package:ayma_flutter/services/app_badge.dart';
import 'package:ayma_flutter/services/notification_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

/// Founder bug (2026-10-28): tapping an Android/iOS system notification opened
/// the app to the item but left the matching in-app notification unread and
/// the bell badge stuck (e.g. "1"). [NotificationService.markReadForTap] must
/// mark the tapped notification read and resync the OS app-icon badge to the
/// new bell count, on both cold-start and warm taps, without over-clearing.
class _FakeBadge implements AppBadge {
  final List<int> counts = [];
  @override
  Future<void> set(int count) async => counts.add(count);
}

NotificationService _svc(FakeFirebaseFirestore fs, AppBadge badge) =>
    NotificationService(
      auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')),
      firestore: fs,
      badge: badge,
    );

Future<void> _seed(FakeFirebaseFirestore fs) async {
  final col = fs.collection('users/me/notifications');
  await col.doc('match').set({
    'type': 'mutual_match',
    'body': 'new match',
    'deep_link': 'profile/bob',
    'read': false,
    'created_at': Timestamp.fromMillisecondsSinceEpoch(1000),
  });
  await col.doc('dive').set({
    'type': 'skill_result',
    'body': 'deep dive ready',
    'deep_link': 'deep_dive/xyz',
    'read': false,
    'created_at': Timestamp.fromMillisecondsSinceEpoch(2000),
  });
}

Future<bool> _read(FakeFirebaseFirestore fs, String id) async {
  final d = await fs.doc('users/me/notifications/$id').get();
  return d.data()!['read'] as bool;
}

void main() {
  test('notif_id marks that exact notification read; others stay unread',
      () async {
    final fs = FakeFirebaseFirestore();
    final badge = _FakeBadge();
    await _seed(fs);
    final svc = _svc(fs, badge);
    expect(await svc.watchUnreadCount().first, 2);

    await svc.markReadForTap({'deep_link': 'profile/bob', 'notif_id': 'match'});

    expect(await _read(fs, 'match'), isTrue);
    expect(await _read(fs, 'dive'), isFalse); // not over-cleared
    expect(await svc.watchUnreadCount().first, 1);
    // OS app-icon badge was resynced to the new unread count.
    expect(badge.counts.last, 1);
  });

  test('legacy push with only deep_link falls back to the matching doc',
      () async {
    final fs = FakeFirebaseFirestore();
    final badge = _FakeBadge();
    await _seed(fs);
    final svc = _svc(fs, badge);

    // No notif_id (push predates the backend field): match by target.
    await svc.markReadForTap({'deep_link': 'deep_dive/xyz'});

    expect(await _read(fs, 'dive'), isTrue);
    expect(await _read(fs, 'match'), isFalse);
    expect(badge.counts.last, 1);
  });

  test('deep_link fallback marks only the most recent match, not all',
      () async {
    final fs = FakeFirebaseFirestore();
    final badge = _FakeBadge();
    final col = fs.collection('users/me/notifications');
    await col.doc('old').set({
      'type': 'ayma_checkin',
      'body': 'older',
      'deep_link': 'chat',
      'read': false,
      'created_at': Timestamp.fromMillisecondsSinceEpoch(1000),
    });
    await col.doc('new').set({
      'type': 'ayma_checkin',
      'body': 'newer',
      'deep_link': 'chat',
      'read': false,
      'created_at': Timestamp.fromMillisecondsSinceEpoch(5000),
    });
    final svc = _svc(fs, badge);

    await svc.markReadForTap({'deep_link': 'chat'});

    expect(await _read(fs, 'new'), isTrue); // most recent = likely tapped one
    expect(await _read(fs, 'old'), isFalse); // don't over-clear
    expect(badge.counts.last, 1);
  });

  test('a DM tap clears nothing in the bell but still resyncs the badge',
      () async {
    final fs = FakeFirebaseFirestore();
    final badge = _FakeBadge();
    await _seed(fs);
    final svc = _svc(fs, badge);

    await svc.markReadForTap(
        {'type': 'dm', 'deep_link': 'dm_thread/me__bob', 'notif_id': 'x'});

    // DMs never appear in the centre; nothing here is touched.
    expect(await _read(fs, 'match'), isFalse);
    expect(await _read(fs, 'dive'), isFalse);
    expect(badge.counts.last, 2);
  });

  test('a tap matching no in-app notification leaves everything unread',
      () async {
    final fs = FakeFirebaseFirestore();
    final badge = _FakeBadge();
    await _seed(fs);
    final svc = _svc(fs, badge);

    await svc.markReadForTap({'deep_link': 'matches'});

    expect(await _read(fs, 'match'), isFalse);
    expect(await _read(fs, 'dive'), isFalse);
    expect(badge.counts.last, 2);
  });
}
