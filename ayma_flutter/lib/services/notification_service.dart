import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'api_client.dart' show kInteractiveTimeout;
import 'app_badge.dart';
import 'pair_key.dart';
import 'write_ack.dart';

/// Notification categories (§7.3, §7.7) — must match
/// `functions/bootstrap/notifications_schema.py`.
const notificationCategories = <String, String>{
  'dm_message': 'Direct messages',
  'mutual_match': 'New matches',
  'new_scored_match': 'Ayma found matches',
  'ayma_checkin': 'Ayma check-ins',
  'skill_result': 'Deep dive & match results',
  'ayma_reply': 'Ayma replies',
  'profile_suggestions': 'Public profile updates',
};

/// DMs surface as the Messages tab's unread badge, never in the centre; this
/// type is filtered out so records written before that change disappear too.
const _dmType = 'dm_message';

/// Most-recent notifications the centre lists (§7.3).
const notificationsLimit = 50;

class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.body,
    required this.deepLink,
    required this.read,
    required this.createdAt,
    this.dismissed = false,
    this.actorUid = '',
  });

  final String id;
  final String type;
  final String body;
  final String deepLink;
  final bool read;
  final DateTime? createdAt;

  /// Swiped away in the notification centre — kept as a soft flag so the
  /// backend-authored doc isn't deleted from under a still-in-flight write.
  final bool dismissed;

  /// The other person this is about — the DM sender, the matched user. Drives
  /// grouping + the face/name shown in the centre. May be '' on old records.
  final String actorUid;

  factory AppNotification.fromDoc(
      DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const {};
    return AppNotification(
      id: d.id,
      type: m['type'] as String? ?? '',
      body: m['body'] as String? ?? '',
      deepLink: m['deep_link'] as String? ?? '',
      read: m['read'] as bool? ?? false,
      createdAt: (m['created_at'] as Timestamp?)?.toDate(),
      dismissed: m['dismissed'] as bool? ?? false,
      actorUid: m['actor_uid'] as String? ?? '',
    );
  }

  /// The other user this notification is about — [actorUid] when the backend
  /// set it, else derived from the `dm_thread/{a__b}` or `profile/{uid}` deep
  /// link (older records). '' when it isn't about a specific person.
  String resolveActorUid(String myUid) {
    if (actorUid.isNotEmpty) return actorUid;
    final dm = RegExp(r'^dm_thread/(.+)$').firstMatch(deepLink);
    if (dm != null) {
      final parts = dm.group(1)!.split('__');
      if (parts.length == 2) {
        return parts.firstWhere((p) => p != myUid, orElse: () => '');
      }
    }
    final profile = RegExp(r'^profile/(.+)$').firstMatch(deepLink);
    if (profile != null) return profile.group(1)!;
    return '';
  }
}

/// Reads `users/{uid}/notifications` and `users/{uid}/notification_prefs`
/// (owner-scoped rules) and writes read-state / preference toggles directly —
/// same client-write pattern as the structured profile doc.
class NotificationService {
  NotificationService(
      {FirebaseAuth? auth, FirebaseFirestore? firestore, AppBadge? badge})
      : _auth = auth ?? FirebaseAuth.instance,
        _fsOverride = firestore,
        _badge = badge ?? const AppBadge();

  final FirebaseAuth _auth;
  final FirebaseFirestore? _fsOverride;
  final AppBadge _badge;

  FirebaseFirestore get _db => _fsOverride ?? FirebaseFirestore.instance;

  String get _uid {
    final u = _auth.currentUser?.uid;
    if (u == null) throw StateError('No signed-in user.');
    return u;
  }

  /// The signed-in uid, or '' if none — safe to read in a widget's field
  /// initializer (used to resolve `profile/{uid}` deep links).
  String get currentUid => _auth.currentUser?.uid ?? '';

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('users/$_uid/notifications');

  DocumentReference<Map<String, dynamic>> get _prefsDoc =>
      _db.doc('users/$_uid/notification_prefs/main');

  Stream<List<AppNotification>> watch() => _col
      .orderBy('created_at', descending: true)
      .limit(notificationsLimit)
      .snapshots()
      .map((s) => s.docs
          .map(AppNotification.fromDoc)
          .where((n) => !n.dismissed && n.type != _dmType)
          .toList());

  /// Unread AND not dismissed — "Clear all" / swipe-dismiss only set
  /// `dismissed` (read state is left alone, same as `watch()`'s list), so the
  /// dismissed check has to happen client-side here too: a Firestore
  /// equality filter on `dismissed` would also exclude every notification
  /// that's never had the field written (the backend never sets it on
  /// creation), hiding fresh unread ones from the badge.
  Stream<int> watchUnreadCount() => _col
      .where('read', isEqualTo: false)
      .snapshots()
      .map((s) => s.docs
          .map(AppNotification.fromDoc)
          .where((n) => !n.dismissed && n.type != _dmType)
          .length);

  Future<void> markRead(String id) => awaitServerAck(
      _col.doc(id).set({'read': true}, SetOptions(merge: true)));

  /// One-shot of the bell's unread count — same unread/dismissed/DM filter as
  /// [watchUnreadCount], read once (not a live stream). Used to resync the OS
  /// app-icon badge after a tap marks something read.
  Future<int> currentUnreadCount() async {
    final snap = await _col.where('read', isEqualTo: false).get();
    return snap.docs
        .map(AppNotification.fromDoc)
        .where((n) => !n.dismissed && n.type != _dmType)
        .length;
  }

  /// Push the current bell unread count to the OS app-icon badge so Android's
  /// and iOS's icon badges stay in sync with the in-app bell (§7.6).
  Future<void> syncBadge() async {
    try {
      await _badge.set(await currentUnreadCount());
    } catch (_) {
      // Best-effort — AppBadge already swallows platform errors; a Firestore
      // read failure here must never surface from a tap handler.
    }
  }

  /// Mark the in-app notification a tapped push points at as read, then resync
  /// the OS app-icon badge (§7.6). Fires for both cold-start and warm taps on
  /// Android and iOS — the FCM tap payload is the same on both platforms.
  ///
  /// `notif_id` (set by the backend) names the exact centre doc, so only that
  /// one is marked. Older pushes that predate it carry only `deep_link`; those
  /// fall back to the single most-recent unread notification with that target
  /// — never every notification sharing it (don't over-clear). DMs never
  /// appear in the centre/bell (filtered by [_dmType]); their read state is
  /// the DM thread's own, so a DM tap only resyncs the badge.
  Future<void> markReadForTap(Map<String, dynamic> data) async {
    if (data['type'] == 'dm') {
      await syncBadge();
      return;
    }
    final notifId = (data['notif_id'] as String?)?.trim() ?? '';
    if (notifId.isNotEmpty) {
      await markRead(notifId);
    } else {
      final link = (data['deep_link'] as String?)?.trim() ?? '';
      if (link.isNotEmpty) {
        final snap = await _col.where('read', isEqualTo: false).get();
        final matches = snap.docs
            .map(AppNotification.fromDoc)
            .where((n) =>
                !n.dismissed && n.type != _dmType && n.deepLink == link)
            .toList()
          ..sort((a, b) => (b.createdAt ?? DateTime(0))
              .compareTo(a.createdAt ?? DateTime(0)));
        if (matches.isNotEmpty) await markRead(matches.first.id);
      }
    }
    await syncBadge();
  }

  /// Mark a set of notifications read in one batch — used when a grouped DM
  /// row is opened (all of that sender's unread messages at once).
  Future<void> markReadMany(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final batch = _db.batch();
    for (final id in list) {
      batch.set(_col.doc(id), {'read': true}, SetOptions(merge: true));
    }
    await awaitServerAck(batch.commit());
  }

  Future<void> markAllRead(List<AppNotification> current) async {
    final batch = _db.batch();
    for (final n in current.where((n) => !n.read)) {
      batch.set(_col.doc(n.id), {'read': true}, SetOptions(merge: true));
    }
    await awaitServerAck(batch.commit());
  }

  /// Swipe-to-dismiss one row.
  Future<void> dismiss(String id) => awaitServerAck(
      _col.doc(id).set({'dismissed': true}, SetOptions(merge: true)));

  /// "Clear all" — soft-dismiss every currently-shown notification.
  Future<void> dismissAll(List<AppNotification> current) async {
    final batch = _db.batch();
    for (final n in current) {
      batch.set(_col.doc(n.id), {'dismissed': true}, SetOptions(merge: true));
    }
    await awaitServerAck(batch.commit());
  }

  /// All category flags, defaulting missing keys to `true` (§7.7).
  static Map<String, bool> _parsePrefs(Map<String, dynamic>? stored) {
    final data = stored ?? const {};
    return {
      for (final key in notificationCategories.keys)
        key: data[key] as bool? ?? true,
    };
  }

  Future<Map<String, bool>> readPrefs() async {
    final snap = await _prefsDoc.get().timeout(kInteractiveTimeout);
    return _parsePrefs(snap.data());
  }

  /// Live category flags — the same doc [readPrefs] reads, as a stream.
  /// Ayma's notification-preference commands write this doc server-side
  /// (`users/{uid}/notification_prefs/main`), so a screen rendering these
  /// switches must render from this stream to reflect her changes while
  /// it is open (founder, 2026-11-06: Ayma-driven changes update the
  /// visible UI in real time, everywhere she can drive a change).
  Stream<Map<String, bool>> watchPrefs() =>
      _prefsDoc.snapshots().map((s) => _parsePrefs(s.data()));

  Future<void> setPref(String category, bool enabled) => awaitServerAck(
      _prefsDoc.set({category: enabled}, SetOptions(merge: true)));
}

/// Maps a notification `deep_link` (§7.6) to a client route.
/// `profile/{uid}` opens the DM thread with that user (sorted-pair id).
String deepLinkToRoute(String deepLink, {required String myUid}) {
  assert(myUid.isNotEmpty, 'deepLinkToRoute requires confirmed non-empty myUid');
  if (deepLink == 'plan') return '/profile/plan';
  if (deepLink == 'trial') return '/profile/usage/trial';
  final dm = RegExp(r'^dm_thread/(.+)$').firstMatch(deepLink);
  if (dm != null) return '/dm/${dm.group(1)}';
  final profile = RegExp(r'^profile/(.+)$').firstMatch(deepLink);
  if (profile != null) {
    return '/dm/${sortedPairKey(myUid, profile.group(1)!)}';
  }
  final matchRequest = RegExp(r'^match_request/(.+)$').firstMatch(deepLink);
  if (matchRequest != null) return '/match-request/${matchRequest.group(1)}';
  final match = RegExp(r'^match/(.+)$').firstMatch(deepLink);
  if (match != null) return '/match/${match.group(1)}';
  final deepDive = RegExp(r'^deep_dive/(.+)$').firstMatch(deepLink);
  if (deepDive != null) {
    return '/deep-dive/${Uri.encodeComponent(deepDive.group(1)!)}';
  }
  // The appearance/body report-ready notification (`appearance/{report_id}`),
  // opening the Appearance report screen (`/appearance/:id`).
  final appearance = RegExp(r'^appearance/(.+)$').firstMatch(deepLink);
  if (appearance != null) {
    return '/appearance/${Uri.encodeComponent(appearance.group(1)!)}';
  }
  // A finished AI Date Simulation (`date_sim/{other_uid}/{sim_id}`), reopening
  // that exact sim on the date-sim screen (the sim id rides as a query
  // param). `from=notification` marks the notification origin so Done
  // navigates to the origin profile instead of popping to the list beneath.
  final dateSim = RegExp(r'^date_sim/([^/]+)/(.+)$').firstMatch(deepLink);
  if (dateSim != null) {
    final other = Uri.encodeComponent(dateSim.group(1)!);
    final simId = Uri.encodeQueryComponent(dateSim.group(2)!);
    return '/date-sim/$other?sim_id=$simId&from=notification';
  }
  if (deepLink == 'matches') return '/matches';
  if (deepLink == 'profile_suggestions') return '/profile/me/updates';
  return '/'; // 'chat' and anything unrecognised land on the Ayma tab
}
