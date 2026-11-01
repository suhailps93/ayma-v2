import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'api_client.dart';

/// One scored match as the Matches list / detail renders it (§5.4, §14.3).
class MatchView {
  const MatchView({
    required this.matchId,
    required this.otherUid,
    required this.otherName,
    required this.score,
    required this.myExplanation,
    required this.status,
  });

  final String matchId;
  final String otherUid;
  final String otherName;
  final double score;

  /// This user's own `user_explanation` entry.
  final String myExplanation;
  final String status;
}

/// Reads the current user's scored matches and posts accept/reject.
class MatchService {
  MatchService({FirebaseAuth? auth, FirebaseFirestore? firestore, ApiClient? api})
      : _auth = auth ?? FirebaseAuth.instance,
        _firestoreOverride = firestore,
        _apiOverride = api;

  final FirebaseAuth _auth;
  final FirebaseFirestore? _firestoreOverride;
  final ApiClient? _apiOverride;

  late final ApiClient _api = _apiOverride ?? ApiClient();

  FirebaseFirestore get _db => _firestoreOverride ?? FirebaseFirestore.instance;

  String get _uid {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('No signed-in user.');
    return uid;
  }

  /// "New from Ayma" — matches still awaiting this user's response.
  Stream<List<MatchView>> watchNewMatches() {
    final uid = _uid;
    return _db
        .collection('matches')
        .where('uids', arrayContains: uid)
        .where('status', isEqualTo: 'scored')
        .snapshots()
        .asyncMap((snap) async {
      final views = <MatchView>[];
      for (final doc in snap.docs) {
        views.add(await _toView(doc, uid));
      }
      views.sort((a, b) => b.score.compareTo(a.score));
      return views;
    });
  }

  /// Mutual matches (both sides accepted, or reciprocal Explore likes) — the
  /// "start a conversation" half of the Messages tab (§11.3). Bounded to
  /// [limit] (Phase 2 pagination design §3.2.1) with batched name hydration
  /// (design §3.2.2 client fallback — no N+1 profile reads).
  Stream<List<MatchView>> watchMutualMatches({int limit = 25}) {
    final uid = _uid;
    return _db
        .collection('matches')
        .where('uids', arrayContains: uid)
        .where('status', isEqualTo: 'mutual_interest')
        .limit(limit)
        .snapshots()
        .asyncMap((snap) => _toViews(snap.docs, uid));
  }

  /// Batched view hydration: ONE `POST /profiles/mini` for every match in
  /// the snapshot instead of one `users/$other/profile/main` read per
  /// match. When the backend is unreachable (offline), falls back to
  /// per-profile reads — today's behavior, served from the local cache.
  Future<List<MatchView>> _toViews(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    String uid,
  ) async {
    final others = <String>[];
    for (final doc in docs) {
      final data = doc.data();
      final uids = ((data['uids'] as List?) ?? const []).cast<String>();
      others.add(uids.firstWhere((u) => u != uid, orElse: () => ''));
    }
    var minis = const <String, MiniProfile>{};
    var batched = false;
    final wanted = others.where((o) => o.isNotEmpty).toSet().toList();
    if (wanted.isNotEmpty) {
      try {
        minis = await _api.miniProfiles(wanted);
        batched = true;
      } catch (_) {}
    }
    final views = <MatchView>[];
    for (var i = 0; i < docs.length; i++) {
      views.add(await _toViewBatched(docs[i], uid, others[i],
          batchedName: batched ? minis[others[i]]?.name : null,
          profileFallback: !batched));
    }
    views.sort((a, b) => b.score.compareTo(a.score));
    return views;
  }

  Future<MatchView> _toViewBatched(
    DocumentSnapshot<Map<String, dynamic>> doc,
    String uid,
    String other, {
    String? batchedName,
    bool profileFallback = false,
  }) async {
    final data = doc.data() ?? const <String, dynamic>{};
    final ue = (data['user_explanation'] as Map?)?.cast<String, dynamic>() ?? {};

    var name = (batchedName ?? '').trim();
    if (name.isEmpty && profileFallback) name = await _profileName(other);
    if (name.isEmpty) name = 'Someone';

    return MatchView(
      matchId: doc.id,
      otherUid: other,
      otherName: name,
      score: (data['score'] as num?)?.toDouble() ?? 0,
      myExplanation: (ue[uid] as String?)?.trim() ?? '',
      status: (data['status'] as String?) ?? 'scored',
    );
  }

  Future<String> _profileName(String other) async {
    try {
      final profile = await _db.doc('users/$other/profile/main').get();
      final n = profile.data()?['name'] as String?;
      if (n != null && n.trim().isNotEmpty) return n.trim();
    } catch (_) {}
    return 'Someone';
  }

  Future<MatchView> _toView(
    DocumentSnapshot<Map<String, dynamic>> doc,
    String uid,
  ) async {
    final data = doc.data() ?? const <String, dynamic>{};
    final uids = (data['uids'] as List).cast<String>();
    final other = uids.firstWhere((u) => u != uid, orElse: () => '');
    final ue = (data['user_explanation'] as Map?)?.cast<String, dynamic>() ?? {};

    final name = await _profileName(other);

    return MatchView(
      matchId: doc.id,
      otherUid: other,
      otherName: name,
      score: (data['score'] as num?)?.toDouble() ?? 0,
      myExplanation: (ue[uid] as String?)?.trim() ?? '',
      status: (data['status'] as String?) ?? 'scored',
    );
  }

  Future<void> respond(String matchId, {required bool accept}) => _api
      .respondToMatch(matchId, accept: accept);

  /// Loads one match by id directly — used by the match request screen when
  /// it's reached via a route/deep link (a notification tap) rather than
  /// tapped from an already-loaded [watchNewMatches] list.
  Future<MatchView> fetchMatch(String matchId) async {
    final uid = _uid;
    final doc = await _db.collection('matches').doc(matchId).get();
    if (!doc.exists) {
      throw StateError('No such match: $matchId');
    }
    return _toView(doc, uid);
  }
}
