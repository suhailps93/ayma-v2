import 'package:ayma_flutter/services/notification_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression test for the bell-badge bug: "Clear all" in the notification
/// centre calls [NotificationService.dismissAll], which only sets
/// `dismissed: true` on each doc — it deliberately leaves `read` alone (same
/// as swipe-dismissing a single row). [NotificationService.watchUnreadCount]
/// drives the bell badge and must treat a dismissed notification as no
/// longer counting toward the unread badge, even though it's still `read:
/// false` in Firestore, or the badge goes stale after "Clear all" (founder
/// report: cleared everything, badge still showed 2).
void main() {
  test('watchUnreadCount excludes dismissed notifications', () async {
    final auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));
    final firestore = FakeFirebaseFirestore();
    final col = firestore.collection('users/me/notifications');

    await col.doc('1').set({
      'type': 'skill_result',
      'body': 'hey',
      'deep_link': 'chat',
      'read': false,
      'created_at': Timestamp.now(),
    });
    await col.doc('2').set({
      'type': 'mutual_match',
      'body': 'new match',
      'deep_link': 'profile/b',
      'read': false,
      'created_at': Timestamp.now(),
    });

    final svc = NotificationService(auth: auth, firestore: firestore);

    // Both unread, neither dismissed yet: badge should read 2.
    expect(await svc.watchUnreadCount().first, 2);

    // "Clear all" — soft-dismisses every currently-shown notification, same
    // as NotificationCenterScreen's Clear-all action. Read state is
    // untouched, mirroring dismissAll()'s real Firestore write.
    final items = [
      AppNotification.fromDoc(await col.doc('1').get()),
      AppNotification.fromDoc(await col.doc('2').get()),
    ];
    await svc.dismissAll(items);

    // Confirm dismissAll really did leave `read` alone (it only touches
    // `dismissed`) — otherwise this test wouldn't be exercising the bug.
    final after1 = await col.doc('1').get();
    expect(after1.data()!['read'], false);
    expect(after1.data()!['dismissed'], true);

    // The badge must now reflect reality: nothing left to show.
    expect(await svc.watchUnreadCount().first, 0);
  });

  test('watchUnreadCount still counts unread, non-dismissed notifications',
      () async {
    final auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));
    final firestore = FakeFirebaseFirestore();
    final col = firestore.collection('users/me/notifications');

    // A brand-new notification straight from the backend never has a
    // `dismissed` field written at all — must still count toward the badge.
    await col.doc('1').set({
      'type': 'ayma_checkin',
      'body': 'hi',
      'deep_link': 'chat',
      'read': false,
      'created_at': Timestamp.now(),
    });

    final svc = NotificationService(auth: auth, firestore: firestore);
    expect(await svc.watchUnreadCount().first, 1);
  });
}
