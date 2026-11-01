import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'api_client.dart';
import 'fresh_data.dart';

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

  /// "New from Ayma" — matches still awaiting this user's response, with
  /// Firestore [SnapshotMetadata] freshness (PERF_PLAN Phase 1).
  Stream<FreshData<List<MatchView>>> watchNewMatchesFresh() {
    final uid = _uid;
    return _db
        .collection('matches')
        .where('uids', arrayContains: uid)
        .where('status', isEqualTo: 'scored')
        .snapshots(includeMetadataChanges: true)
        .asyncMap((snap) => _viewsFresh(snap, uid));
  }

  Stream<List<MatchView>> watchNewMatches() =>
      watchNewMatchesFresh().map((f) => f.data ?? const <MatchView>[]);

  /// Mutual matches (both sides accepted, or reciprocal Explore likes) — the
  /// "start a conversation" half of the Messages tab (§11.3), with freshness.
  Stream<FreshData<List<MatchView>>> watchMutualMatchesFresh() {
    final uid = _uid;
    return _db
        .collection('matches')
        .where('uids', arrayContains: uid)
        .where('status', isEqualTo: 'mutual_interest')
        .snapshots(includeMetadataChanges: true)
        .asyncMap((snap) => _viewsFresh(snap, uid));
  }

  Stream<List<MatchView>> watchMutualMatches() =>
      watchMutualMatchesFresh().map((f) => f.data ?? const <MatchView>[]);

  Future<FreshData<List<MatchView>>> _viewsFresh(
    QuerySnapshot<Map<String, dynamic>> snap,
    String uid,
  ) async {
    try {
      final views = <MatchView>[];
      for (final doc in snap.docs) {
        views.add(await _toView(doc, uid));
      }
      views.sort((a, b) => b.score.compareTo(a.score));
      return FreshData<List<MatchView>>(
        data: views,
        isFromCache: snap.metadata.isFromCache,
        hasPendingWrites: snap.metadata.hasPendingWrites,
      );
    } catch (e) {
      return FreshData<List<MatchView>>(error: e);
    }
  }

  Future<MatchView> _toView(
    DocumentSnapshot<Map<String, dynamic>> doc,
    String uid,
  ) async {
    final data = doc.data() ?? const <String, dynamic>{};
    final uids = (data['uids'] as List).cast<String>();
    final other = uids.firstWhere((u) => u != uid, orElse: () => '');
    final ue = (data['user_explanation'] as Map?)?.cast<String, dynamic>() ?? {};

    var name = 'Someone';
    try {
      final profile = await _db
          .doc('users/$other/profile/main')
          .get()
          .timeout(kInteractiveTimeout);
      final n = profile.data()?['name'] as String?;
      if (n != null && n.trim().isNotEmpty) name = n.trim();
    } catch (_) {}

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
  /// tapped from an already-loaded [watchNewMatches] list. Enforces
  /// [kInteractiveTimeout] so network drops fail fast instead of hanging.
  Future<MatchView> fetchMatch(String matchId) async {
    final uid = _uid;
    final doc = await _db
        .collection('matches')
        .doc(matchId)
        .get()
        .timeout(kInteractiveTimeout);
    if (!doc.exists) {
      throw StateError('No such match: $matchId');
    }
    return _toView(doc, uid);
  }
}
