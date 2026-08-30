import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Notification categories (§7.3, §7.7) — must match
/// `functions/bootstrap/notifications_schema.py`.
const notificationCategories = <String, String>{
  'dm_message': 'Direct messages',
  'mutual_match': 'New matches',
  'new_scored_match': 'Ayma found matches',
  'ayma_checkin': 'Ayma check-ins',
};

/// Most-recent notifications the centre lists — mirrors backend
/// `NOTIFICATIONS_LIMIT` (§7.3).
const notificationsLimit = 50;

class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.body,
    required this.deepLink,
    required this.read,
    required this.createdAt,
  });

  final String id;
  final String type;
  final String body;
  final String deepLink;
  final bool read;
  final DateTime? createdAt;

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
    );
  }
}

/// Reads `users/{uid}/notifications` and `users/{uid}/notification_prefs`
/// (owner-scoped rules) and writes read-state / preference toggles directly —
/// same client-write pattern as the structured profile doc.
class NotificationService {
  NotificationService({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _auth = auth ?? FirebaseAuth.instance,
        _fsOverride = firestore;

  final FirebaseAuth _auth;
  final FirebaseFirestore? _fsOverride;

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
      .map((s) => s.docs.map(AppNotification.fromDoc).toList());

  Stream<int> watchUnreadCount() => _col
      .where('read', isEqualTo: false)
      .snapshots()
      .map((s) => s.docs.length);

  Future<void> markRead(String id) =>
      _col.doc(id).set({'read': true}, SetOptions(merge: true));

  Future<void> markAllRead(List<AppNotification> current) async {
    final batch = _db.batch();
    for (final n in current.where((n) => !n.read)) {
      batch.set(_col.doc(n.id), {'read': true}, SetOptions(merge: true));
    }
    await batch.commit();
  }

  /// All four category flags, defaulting missing keys to `true` (§7.7).
  Future<Map<String, bool>> readPrefs() async {
    final snap = await _prefsDoc.get();
    final stored = snap.data() ?? const {};
    return {
      for (final key in notificationCategories.keys)
        key: stored[key] as bool? ?? true,
    };
  }

  Future<void> setPref(String category, bool enabled) =>
      _prefsDoc.set({category: enabled}, SetOptions(merge: true));
}

/// Maps a notification `deep_link` (§7.6) to a client route.
/// `profile/{uid}` opens the DM thread with that user (sorted-pair id).
String deepLinkToRoute(String deepLink, {required String myUid}) {
  final dm = RegExp(r'^dm_thread/(.+)$').firstMatch(deepLink);
  if (dm != null) return '/dm/${dm.group(1)}';
  final profile = RegExp(r'^profile/(.+)$').firstMatch(deepLink);
  if (profile != null) {
    return '/dm/${_sortedPairKey(myUid, profile.group(1)!)}';
  }
  if (deepLink == 'matches') return '/matches';
  return '/'; // 'chat' and anything unrecognised land on the Ayma tab
}

String _sortedPairKey(String a, String b) {
  final lo = a.compareTo(b) <= 0 ? a : b;
  final hi = a.compareTo(b) <= 0 ? b : a;
  return '${lo}__$hi';
}
