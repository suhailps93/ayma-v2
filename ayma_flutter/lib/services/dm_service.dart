import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'api_client.dart';
import 'fresh_data.dart';

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
    this.reportShare,
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

  /// `shared_report` only — the shared report's token, title, summary and
  /// public card image.
  final DmReportShare? reportShare;

  bool get isSharedReport => type == 'shared_report' && reportShare != null;

  bool get hasImage => type == 'image' && attachmentUrl.isNotEmpty;
  bool get hasGif => type == 'gif' && attachmentUrl.isNotEmpty;
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
        reportShare: DmReportShare.tryParse(m['report_share']),
      );
}

/// The `report_share` map of a `shared_report` DM message.
class DmReportShare {
  const DmReportShare({
    required this.token,
    required this.title,
    required this.summary,
    required this.cardUrl,
  });

  final String token;
  final String title;
  final String summary;
  final String cardUrl;

  static DmReportShare? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final token = raw['token'] as String? ?? '';
    if (token.isEmpty) return null;
    return DmReportShare(
      token: token,
      title: raw['title'] as String? ?? '',
      summary: raw['summary'] as String? ?? '',
      cardUrl: raw['card_url'] as String? ?? '',
    );
  }
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

  /// Active conversations, newest first, bounded to [limit] (Phase 2
  /// pagination design §3.2.1: the top-25 real-time tier) with Firestore
  /// [SnapshotMetadata] freshness (PERF_PLAN Phase 1). Older threads page in
  /// on demand via [fetchOlderThreads]. Uses `includeMetadataChanges` so
  /// cache→server transitions emit.
  Stream<FreshData<List<DmThread>>> watchThreadsFresh({int limit = 25}) {
    final me = uid;
    return _threadsQuery(limit: limit)
        .snapshots(includeMetadataChanges: true)
        .map((snap) => FreshData.fromQuery(snap, (s) => _mapThreads(s, me)));
  }

  Stream<List<DmThread>> watchThreads({int limit = 25}) =>
      watchThreadsFresh(limit: limit).map((f) => f.data ?? const <DmThread>[]);

  Query<Map<String, dynamic>> _threadsQuery({int? limit}) {
    Query<Map<String, dynamic>> q = _db
        .collection('dm_threads')
        .where('participants', arrayContains: uid)
        .orderBy('last_message_at', descending: true);
    if (limit != null) q = q.limit(limit);
    return q;
  }

  List<DmThread> _mapThreads(
    QuerySnapshot<Map<String, dynamic>> snap,
    String me,
  ) {
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
  }

  /// One-shot top-[limit] threads, newest first — the idle tab warm-up's
  /// conversation snapshot (design §4.2). Same query as [watchThreads].
  Future<List<DmThread>> fetchActiveThreads({int limit = 25}) async {
    final me = uid;
    final snap = await _threadsQuery(limit: limit).get();
    return _mapThreads(snap, me);
  }

  /// Total unread DM messages across ALL visible threads (nav-bar badge).
  /// Deliberately unbounded: the badge must count threads past the §3.2.1
  /// top-25 listener tier too.
  Stream<int> watchTotalUnread() {
    final me = uid;
    return _threadsQuery()
        .snapshots()
        .map((snap) => _mapThreads(snap, me)
            .fold(0, (total, t) => total + t.unread));
  }

  /// One-shot archive page (design §3.2.3): up to [limit] threads older
  /// than [lastThreadId] (exclusive), newest first. Callers deduplicate by
  /// thread id against the live tier (design §6.2). A deleted anchor ends
  /// the archive rather than erroring it.
  Future<List<DmThread>> fetchOlderThreads({
    required String lastThreadId,
    int limit = 25,
  }) async {
    final me = uid;
    final anchor = await _db.doc('dm_threads/$lastThreadId').get();
    if (!anchor.exists) return const [];
    final snap = await _db
        .collection('dm_threads')
        .where('participants', arrayContains: me)
        .orderBy('last_message_at', descending: true)
        .startAfterDocument(anchor)
        .limit(limit)
        .get();
    return _mapThreads(snap, me);
  }

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

  /// Mark every thread with unread messages read for me — the Messages
  /// tab's "Mark all read" button and Ayma's `mark_all_conversations_read`
  /// command. Pages past the live top tier so threads below the fold
  /// count too. Returns how many threads were marked.
  Future<int> markAllThreadsRead() async {
    final byId = <String, DmThread>{};
    var page = await fetchActiveThreads(limit: 100);
    for (var guard = 0; guard < 40; guard++) {
      for (final t in page) {
        byId[t.threadId] = t;
      }
      if (page.length < 100) break;
      page = await fetchOlderThreads(lastThreadId: page.last.threadId, limit: 100);
      if (page.isEmpty) break;
    }
    final unread = byId.values.where((t) => t.unread > 0).toList();
    for (final t in unread) {
      await markThreadRead(t.threadId);
    }
    return unread.length;
  }

  /// The other participant in a sorted-pair thread id (`{lo}__{hi}`).
  String otherUidOf(String threadId) {
    final me = uid;
    return threadId.split('__').firstWhere((p) => p != me, orElse: () => '');
  }

  /// Live DM coaching for a thread (§6.9): suggestion chips + an optional
  /// one-line tip, derived from the recent [messages] tail (oldest-first, as
  /// delivered by [watchMessages]). Sends up to the last 12 messages; an empty
  /// list asks for opener suggestions on a brand-new thread.
  Future<DmAssist> assist(String threadId, List<DmMessage> messages) {
    final me = uid;
    final start = messages.length > 12 ? messages.length - 12 : 0;
    final tail = <Map<String, String>>[
      for (final m in messages.skip(start))
        {'from': m.senderUid == me ? 'me' : 'them', 'text': _assistText(m)},
    ];
    return _api.dmAssist(other: otherUidOf(threadId), messages: tail);
  }

  /// The text the coach sees for a message. Text and attachment captions carry
  /// the user's own words; typed, body-less messages (a bare photo, a voice
  /// note, a shared card) send a short placeholder so the turn still counts in
  /// the back-and-forth without leaking a raw storage path.
  String _assistText(DmMessage m) {
    final body = m.body.trim();
    switch (m.type) {
      case 'text':
        return body;
      case 'image':
      case 'file':
        return body; // caption, if any
      case 'gif':
        return body.isNotEmpty ? body : '[gif]';
      case 'photo':
        return '[photo]';
      case 'voice':
        return '[voice message]';
      case 'shared_profile':
        return '[shared a profile]';
      case 'shared_report':
        return '[shared a report]';
      default:
        return body;
    }
  }

  /// Cross-language DM translation (§6.12): translate [text] into [targetLang]
  /// (a language code or name), scoped to this thread. Returns the translation
  /// plus the detected source language. Never blocks the thread — the backend
  /// returns the original text on any model failure.
  Future<DmTranslation> translate(
    String threadId,
    String text,
    String targetLang, {
    String sourceLang = '',
  }) =>
      _api.dmTranslate(
        threadId: threadId,
        text: text,
        targetLang: targetLang,
        sourceLang: sourceLang,
      );

  /// Block & report the other participant (§6.5); hides the thread for us.
  Future<void> block(String otherUid) => _api.block(otherUid);

  /// Newest [limit] messages as a live tail, oldest-first (Phase 2
  /// pagination design §3.3.1) with Firestore [SnapshotMetadata] freshness
  /// (PERF_PLAN Phase 1). Older history pages in on demand via
  /// [fetchOlderMessages]. Oldest-first is the established contract (see
  /// [assist]); the DESC limit is applied server-side. Uses
  /// `includeMetadataChanges` so cache→server transitions emit.
  Stream<FreshData<List<DmMessage>>> watchMessagesFresh(
    String threadId, {
    int limit = 30,
  }) =>
      _db
          .collection('dm_threads/$threadId/messages')
          .orderBy('created_at', descending: true)
          .limit(limit)
          .snapshots(includeMetadataChanges: true)
          .map((snap) => FreshData.fromQuery(
                snap,
                (s) => s.docs
                    .map((d) => DmMessage.fromData(d.id, d.data()))
                    .toList()
                    .reversed
                    .toList(),
              ));

  Stream<List<DmMessage>> watchMessages(String threadId, {int limit = 30}) =>
      watchMessagesFresh(threadId, limit: limit)
          .map((f) => f.data ?? const <DmMessage>[]);

  /// One-shot history page (design §3.3.2): up to [limit] messages older
  /// than [lastMessageId] (exclusive), oldest-first. A deleted anchor ends
  /// history rather than erroring it.
  Future<List<DmMessage>> fetchOlderMessages(
    String threadId, {
    required String lastMessageId,
    int limit = 30,
  }) async {
    final anchor =
        await _db.doc('dm_threads/$threadId/messages/$lastMessageId').get();
    if (!anchor.exists) return const [];
    final snap = await _db
        .collection('dm_threads/$threadId/messages')
        .orderBy('created_at', descending: true)
        .startAfterDocument(anchor)
        .limit(limit)
        .get();
    return snap.docs
        .map((d) => DmMessage.fromData(d.id, d.data()))
        .toList()
        .reversed
        .toList();
  }

  Future<void> sendText(String threadId, String text) =>
      _api.sendDmMessage(threadId, type: 'text', body: text);

  Future<void> sendPhoto(String threadId, String storagePath) =>
      _api.sendDmMessage(threadId, type: 'photo', body: storagePath);

  Future<void> sendVoice(String threadId, String storagePath) =>
      _api.sendDmMessage(threadId, type: 'voice', body: storagePath);

  /// Upload a recorded voice-note clip to
  /// `uploads/{myUid}/dm/{threadId}/voice_{ts}.wav` (the path shape the
  /// `/dm/{threadId}/messages` voice contract requires: the message body
  /// must be a path under the sender's `uploads/`). Returns the attachment
  /// descriptor; send it with [sendVoice] using its storage path.
  Future<DmAttachment> uploadVoiceClip(
    File file, {
    required String threadId,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final name = 'voice_$ts.wav';
    final path = 'uploads/$uid/dm/$threadId/$name';
    final ref = _storage.ref(path);
    await ref.putFile(file, SettableMetadata(contentType: 'audio/wav'));
    return DmAttachment(
      storagePath: path,
      downloadUrl: await ref.getDownloadURL(),
      contentType: 'audio/wav',
      sizeBytes: await file.length(),
      name: name,
    );
  }

  /// A playable download URL for a stored voice note (its message body is
  /// the storage path, not a URL). Null when it cannot be resolved right
  /// now (transient failure) - the bubble stays a labelled placeholder.
  Future<String?> voiceDownloadUrl(String storagePath) async {
    try {
      return await _storage.ref(storagePath).getDownloadURL();
    } catch (_) {
      return null;
    }
  }

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

  /// Upload raw [bytes] that came from the keyboard's GIF/image button
  /// (rich-content insertion, §6.6) — which hands the app bytes, not a file on
  /// disk — to `uploads/{myUid}/dm/{threadId}/inserted_{ts}{ext}` and return the
  /// attachment for [sendAttachment]. [mime] is the content type the keyboard
  /// reported (e.g. `image/gif`); the extension is derived from it.
  Future<DmAttachment> uploadInsertedAttachment(
    Uint8List bytes, {
    required String threadId,
    required String mime,
  }) async {
    final ext = _extForMime(mime);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final name = 'inserted_$ts$ext';
    final path = 'uploads/$uid/dm/$threadId/$name';
    final ref = _storage.ref(path);
    await ref.putData(bytes, SettableMetadata(contentType: mime));
    return DmAttachment(
      storagePath: path,
      downloadUrl: await ref.getDownloadURL(),
      contentType: mime,
      sizeBytes: bytes.length,
      name: name,
    );
  }

  /// Send an already-uploaded [attachment] as an `image`, `gif` or `file`
  /// message, with an optional [caption].
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

/// The file extension (with leading dot) for a keyboard-inserted media MIME
/// type, used to name the uploaded object. Covers what Gboard/keyboards insert
/// (GIF, PNG, JPEG, WebP); an unknown type gets no extension.
String _extForMime(String mime) {
  switch (mime.toLowerCase()) {
    case 'image/gif':
      return '.gif';
    case 'image/png':
      return '.png';
    case 'image/jpeg':
    case 'image/jpg':
      return '.jpg';
    case 'image/webp':
      return '.webp';
    default:
      return '';
  }
}
