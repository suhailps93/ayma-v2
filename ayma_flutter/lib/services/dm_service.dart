import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'api_client.dart';

class DmThread {
  const DmThread({
    required this.threadId,
    required this.otherUid,
    required this.lastMessageAt,
    this.unread = 0,
  });
  final String threadId;
  final String otherUid;
  final DateTime? lastMessageAt;

  /// Messages from the other participant not yet seen by me.
  final int unread;
}

class DmMessage {
  const DmMessage({
    required this.id,
    required this.senderUid,
    required this.type,
    required this.body,
    required this.createdAt,
    this.attachmentUrl = '',
    this.attachmentPath = '',
    this.mime = '',
    this.fileName = '',
    this.size = 0,
    this.moderated = false,
  });
  final String id;
  final String senderUid;
  final String type; // text | photo | voice | shared_profile | image | file
  final String body; // caption for image/file, the message for text
  final DateTime? createdAt;

  /// image/file only — the ready-to-render download URL and its storage path.
  final String attachmentUrl;
  final String attachmentPath;
  final String mime;
  final String fileName;
  final int size;

  /// Set server-side when text moderation flagged this message. The text is
  /// still delivered in full — this only marks it for a visible warning.
  final bool moderated;

  bool get hasImage => type == 'image' && attachmentUrl.isNotEmpty;
  bool get hasFile => type == 'file' && attachmentUrl.isNotEmpty;

  /// Build a message from a Firestore doc id + its raw data map.
  factory DmMessage.fromData(String id, Map<String, dynamic> m) => DmMessage(
        id: id,
        senderUid: m['sender_uid'] as String? ?? '',
        type: m['type'] as String? ?? 'text',
        body: m['body'] as String? ?? '',
        createdAt: (m['created_at'] as Timestamp?)?.toDate(),
        attachmentUrl: m['attachment_url'] as String? ?? '',
        attachmentPath: m['attachment_path'] as String? ?? '',
        mime: m['mime'] as String? ?? '',
        fileName: m['file_name'] as String? ?? '',
        size: (m['size'] as num?)?.toInt() ?? 0,
        moderated: m['moderated'] as bool? ?? false,
      );
}

/// An uploaded DM attachment, ready to send via [DmService.sendAttachment].
class DmAttachment {
  const DmAttachment({
    required this.storagePath,
    required this.downloadUrl,
    required this.contentType,
    required this.sizeBytes,
    required this.name,
  });
  final String storagePath;
  final String downloadUrl;
  final String contentType;
  final int sizeBytes;
  final String name;
}

/// Reads DM threads/messages (participant-scoped rules) and sends via the API.
class DmService {
  DmService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    ApiClient? api,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _fsOverride = firestore,
        _storageOverride = storage,
        _apiOverride = api;

  final FirebaseAuth _auth;
  final FirebaseFirestore? _fsOverride;
  final FirebaseStorage? _storageOverride;
  final ApiClient? _apiOverride;

  FirebaseFirestore get _db => _fsOverride ?? FirebaseFirestore.instance;
  FirebaseStorage get _storage => _storageOverride ?? FirebaseStorage.instance;
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
      final threads = snap.docs
          .where((d) =>
              !((d.data()['hidden_for'] as List?)?.cast<String>() ?? const [])
                  .contains(me))
          .map((d) {
        final data = d.data();
        final parts = (data['participants'] as List).cast<String>();
        return DmThread(
          threadId: d.id,
          otherUid: parts.firstWhere((p) => p != me, orElse: () => ''),
          lastMessageAt: (data['last_message_at'] as Timestamp?)?.toDate(),
          unread: (((data['unread'] as Map?)?[me]) as num?)?.toInt() ?? 0,
        );
      }).toList()
        ..sort((a, b) => (b.lastMessageAt ?? DateTime(0))
            .compareTo(a.lastMessageAt ?? DateTime(0)));
      return threads;
    });
  }

  /// Total unread DM messages across all visible threads (nav-bar badge).
  Stream<int> watchTotalUnread() =>
      watchThreads().map((ts) => ts.fold(0, (total, t) => total + t.unread));

  /// Mark [threadId] read for me: zero my unread counter and stamp my read
  /// cursor. Writes only my own entries (see `firestore.rules`). Best-effort —
  /// a missing thread doc (no message sent yet) or offline write is ignored.
  Future<void> markThreadRead(String threadId) async {
    final me = uid;
    try {
      await _db.doc('dm_threads/$threadId').update({
        'unread.$me': 0,
        'last_read_at.$me': FieldValue.serverTimestamp(),
      });
    } on FirebaseException {
      // Thread doc not created yet, or a transient failure: nothing to mark.
    }
  }

  /// The other participant in a sorted-pair thread id (`{lo}__{hi}`).
  String otherUidOf(String threadId) {
    final me = uid;
    return threadId.split('__').firstWhere((p) => p != me, orElse: () => '');
  }

  /// Suggested opener chips for a thread (§6.9); empty when none apply.
  Future<List<String>> icebreakers(String threadId) =>
      _api.dmIcebreakers(threadId);

  /// Block & report the other participant (§6.5); hides the thread for us.
  Future<void> block(String otherUid) => _api.block(otherUid);

  Stream<List<DmMessage>> watchMessages(String threadId) => _db
      .collection('dm_threads/$threadId/messages')
      .orderBy('created_at')
      .snapshots()
      .map((snap) => snap.docs
          .map((d) => DmMessage.fromData(d.id, d.data()))
          .toList());

  Future<void> sendText(String threadId, String text) =>
      _api.sendDmMessage(threadId, type: 'text', body: text);

  Future<void> sendPhoto(String threadId, String storagePath) =>
      _api.sendDmMessage(threadId, type: 'photo', body: storagePath);

  Future<void> sendVoice(String threadId, String storagePath) =>
      _api.sendDmMessage(threadId, type: 'voice', body: storagePath);

  /// Upload [file] to `uploads/{myUid}/dm/{threadId}/{ts}.{ext}` and return its
  /// storage path + download URL for [sendAttachment].
  Future<DmAttachment> uploadAttachment(
    File file, {
    required String threadId,
  }) async {
    final name = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : 'file';
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.')).toLowerCase()
        : '';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = 'uploads/$uid/dm/$threadId/$ts$ext';
    final mime = _mimeForExt(ext);
    final ref = _storage.ref(path);
    await ref.putFile(file, SettableMetadata(contentType: mime));
    return DmAttachment(
      storagePath: path,
      downloadUrl: await ref.getDownloadURL(),
      contentType: mime,
      sizeBytes: await file.length(),
      name: name,
    );
  }

  /// Send an already-uploaded [attachment] as an `image` or `file` message,
  /// with an optional [caption].
  Future<void> sendAttachment(
    String threadId, {
    required String type,
    required DmAttachment attachment,
    String caption = '',
  }) =>
      _api.sendDmMessage(
        threadId,
        type: type,
        body: caption,
        attachmentUrl: attachment.downloadUrl,
        attachmentPath: attachment.storagePath,
        mime: attachment.contentType,
        fileName: attachment.name,
        size: attachment.sizeBytes,
      );
}

/// A small MIME guess from a file extension — Storage/`url_launcher` do the
/// rest; falls back to a generic binary type.
String _mimeForExt(String ext) {
  switch (ext.replaceFirst('.', '')) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'heic':
      return 'image/heic';
    case 'pdf':
      return 'application/pdf';
    case 'txt':
      return 'text/plain';
    case 'csv':
      return 'text/csv';
    case 'doc':
      return 'application/msword';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xls':
      return 'application/vnd.ms-excel';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case 'ppt':
      return 'application/vnd.ms-powerpoint';
    case 'pptx':
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    case 'zip':
      return 'application/zip';
    case 'mp3':
      return 'audio/mpeg';
    case 'mp4':
      return 'video/mp4';
    default:
      return 'application/octet-stream';
  }
}
