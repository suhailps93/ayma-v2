import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'api_client.dart';

class DmThread {
  const DmThread({
    required this.threadId,
    required this.otherUid,
    required this.lastMessageAt,
  });
  final String threadId;
  final String otherUid;
  final DateTime? lastMessageAt;
}

class DmMessage {
  const DmMessage({
    required this.id,
    required this.senderUid,
    required this.type,
    required this.body,
    required this.createdAt,
  });
  final String id;
  final String senderUid;
  final String type; // text | photo | voice | shared_profile
  final String body;
  final DateTime? createdAt;
}

/// Reads DM threads/messages (participant-scoped rules) and sends via the API.
class DmService {
  DmService({FirebaseAuth? auth, FirebaseFirestore? firestore, ApiClient? api})
      : _auth = auth ?? FirebaseAuth.instance,
        _fsOverride = firestore,
        _apiOverride = api;

  final FirebaseAuth _auth;
  final FirebaseFirestore? _fsOverride;
  final ApiClient? _apiOverride;

  FirebaseFirestore get _db => _fsOverride ?? FirebaseFirestore.instance;
  late final ApiClient _api = _apiOverride ?? ApiClient();

  String get uid {
    final u = _auth.currentUser?.uid;
    if (u == null) throw StateError('No signed-in user.');
    return u;
  }

  Stream<List<DmThread>> watchThreads() {
    final me = uid;
    return _db
        .collection('dm_threads')
        .where('participants', arrayContains: me)
        .snapshots()
        .map((snap) {
      final threads = snap.docs.map((d) {
        final data = d.data();
        final parts = (data['participants'] as List).cast<String>();
        return DmThread(
          threadId: d.id,
          otherUid: parts.firstWhere((p) => p != me, orElse: () => ''),
          lastMessageAt: (data['last_message_at'] as Timestamp?)?.toDate(),
        );
      }).toList()
        ..sort((a, b) => (b.lastMessageAt ?? DateTime(0))
            .compareTo(a.lastMessageAt ?? DateTime(0)));
      return threads;
    });
  }

  Stream<List<DmMessage>> watchMessages(String threadId) => _db
      .collection('dm_threads/$threadId/messages')
      .orderBy('created_at')
      .snapshots()
      .map((snap) => snap.docs
          .map((d) => DmMessage(
                id: d.id,
                senderUid: d.data()['sender_uid'] as String? ?? '',
                type: d.data()['type'] as String? ?? 'text',
                body: d.data()['body'] as String? ?? '',
                createdAt: (d.data()['created_at'] as Timestamp?)?.toDate(),
              ))
          .toList());

  Future<void> sendText(String threadId, String text) =>
      _api.sendDmMessage(threadId, type: 'text', body: text);

  Future<void> sendPhoto(String threadId, String storagePath) =>
      _api.sendDmMessage(threadId, type: 'photo', body: storagePath);

  Future<void> sendVoice(String threadId, String storagePath) =>
      _api.sendDmMessage(threadId, type: 'voice', body: storagePath);
}
