import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'api_client.dart';

/// One tile in the profile-photo grid (§8.3).
class GridPhoto {
  const GridPhoto({
    required this.mediaId,
    required this.order,
    required this.downloadUrl,
  });

  final String mediaId;
  final int order;
  final String downloadUrl;
}

/// Backs the photo-management screen (§8.7 step 6): loads the grid (resolving
/// each `media_id` to a download URL), uploads new photos through the pipeline,
/// and proxies add / remove / reorder plus the Instagram actions.
class PhotoService {
  PhotoService({
    ApiClient? api,
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
  })  : _apiOverride = api,
        _authOverride = auth,
        _fsOverride = firestore,
        _storageOverride = storage;

  final ApiClient? _apiOverride;
  final FirebaseAuth? _authOverride;
  final FirebaseFirestore? _fsOverride;
  final FirebaseStorage? _storageOverride;

  late final ApiClient _api = _apiOverride ?? ApiClient();
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;
  FirebaseFirestore get _db => _fsOverride ?? FirebaseFirestore.instance;
  FirebaseStorage get _storage => _storageOverride ?? FirebaseStorage.instance;

  String get _uid {
    final u = _auth.currentUser?.uid;
    if (u == null) throw StateError('No signed-in user.');
    return u;
  }

  Future<List<GridPhoto>> loadGrid() async {
    final entries = await _api.listPhotos();
    final out = <GridPhoto>[];
    for (final e in entries) {
      final mediaId = e['media_id'] as String? ?? '';
      if (mediaId.isEmpty) continue;
      final url = await _downloadUrl(mediaId);
      if (url == null) continue;
      out.add(GridPhoto(
        mediaId: mediaId,
        order: (e['order'] as num?)?.toInt() ?? out.length,
        downloadUrl: url,
      ));
    }
    out.sort((a, b) => a.order.compareTo(b.order));
    return out;
  }

  Future<String?> _downloadUrl(String mediaId) async {
    try {
      final doc = await _db.doc('users/$_uid/user_media/$mediaId').get();
      final path = doc.data()?['storage_path'] as String?;
      if (path == null || path.isEmpty) return null;
      return await _storage.ref(path).getDownloadURL();
    } catch (_) {
      return null;
    }
  }

  /// Upload every file in [files] (photos picked together in one "add
  /// photos" action) to `uploads/{uid}/…` and run the §8.5 pipeline on each,
  /// in order. A file that fails moderation (or fails to upload) is dropped
  /// into [PhotoUploadBatch.rejected] with a reason, rather than throwing —
  /// the caller adds whatever passed with [addToGridBatch].
  Future<PhotoUploadBatch> uploadAndProcessAll(List<File> files) async {
    // Upload and register every picked file concurrently rather than one at a
    // time — each is an independent Storage put + pipeline round-trip, so the
    // batch finishes in roughly the time of the slowest photo instead of their
    // sum. [Future.wait] preserves input order, so the results stay in the
    // order the user picked them (index 0 = would-be primary).
    final uid = _uid;
    final outcomes = await Future.wait([
      for (var i = 0; i < files.length; i++) _uploadOne(uid, files[i], i),
    ]);
    final mediaIds = <String>[];
    final storagePaths = <String>[];
    final rejected = <String>[];
    for (final o in outcomes) {
      if (o.mediaId != null) {
        mediaIds.add(o.mediaId!);
        storagePaths.add(o.storagePath!);
      } else {
        rejected.add(o.reason ?? "can't be used");
      }
    }
    return PhotoUploadBatch(
      mediaIds: mediaIds, storagePaths: storagePaths, rejected: rejected);
  }

  /// Upload one picked file to `uploads/{uid}/…` and run the §8.5 pipeline on
  /// it. Never throws — a failure (upload or moderation reject) comes back as
  /// an [_UploadOutcome] with a reason, so one bad photo can't sink the batch.
  /// [index] makes the storage path unique within a concurrent batch.
  Future<_UploadOutcome> _uploadOne(String uid, File file, int index) async {
    try {
      final ext = file.path.contains('.')
          ? file.path.substring(file.path.lastIndexOf('.'))
          : '.jpg';
      final path = 'uploads/$uid/photo_'
          '${DateTime.now().millisecondsSinceEpoch}_$index$ext';
      await _storage.ref(path).putFile(file);
      final media = await _api.registerMedia(path, context: 'profile');
      if (media.published && media.mediaId.isNotEmpty) {
        return _UploadOutcome.added(media.mediaId, path);
      }
      return _UploadOutcome.rejected(
          media.reason.isEmpty ? "can't be used" : media.reason);
    } catch (_) {
      return _UploadOutcome.rejected('upload failed');
    }
  }

  /// `POST /media/photos/batch` — add several already-processed photos to
  /// the grid in one call (§ appearance batching): the whole set is analysed
  /// together as one update to the caller's single persistent Appearance
  /// report, instead of N separate per-photo runs.
  Future<PhotoBatchResult> addToGridBatch(List<String> mediaIds) =>
      _api.addPhotosBatch(mediaIds);

  /// Re-run reverse-image search on the given already-uploaded photos (§ web
  /// photo search) — call right after a successful post-onboarding
  /// [addToGridBatch] so newly added photos get searched too. Always
  /// queued server-side; safe to ignore failures.
  Future<void> rescanWebSearchPhotos(List<String> storagePaths) =>
      _api.rescanWebSearchPhotos(storagePaths: storagePaths);

  /// Remove from the public profile only — kept privately for analysis (§8.3).
  Future<void> remove(String mediaId) => _api.removePhoto(mediaId);

  /// Make [mediaId] the primary (hero) public photo.
  Future<void> setPrimary(String mediaId) => _api.setPrimaryPhoto(mediaId);

  /// Delete everywhere — erases the photo and its analysis. Not reversible.
  Future<void> deletePermanent(String mediaId) =>
      _api.deletePhotoPermanent(mediaId);

  Future<void> reorder(List<String> mediaIds) => _api.reorderPhotos(mediaIds);

  Future<String> instagramAuthUrl() => _api.instagramAuthUrl();

  Future<int> instagramConnect(String code) => _api.instagramConnect(code);

  Future<void> instagramDisconnect() => _api.instagramDisconnect();
}

/// Outcome of a single file's upload+register within
/// [PhotoService.uploadAndProcessAll]. Exactly one of ([mediaId]/[storagePath])
/// or [reason] is set: added photos carry their ids, a rejected or failed one
/// carries why.
class _UploadOutcome {
  const _UploadOutcome._({this.mediaId, this.storagePath, this.reason});

  factory _UploadOutcome.added(String mediaId, String storagePath) =>
      _UploadOutcome._(mediaId: mediaId, storagePath: storagePath);

  factory _UploadOutcome.rejected(String reason) =>
      _UploadOutcome._(reason: reason);

  final String? mediaId;
  final String? storagePath;
  final String? reason;
}

/// Result of [PhotoService.uploadAndProcessAll] — one batch of photos picked
/// together in a single "add photos" action. [mediaIds] / [storagePaths]
/// cover only the photos that passed moderation, in order; [rejected] holds
/// one reason string per photo that didn't.
class PhotoUploadBatch {
  const PhotoUploadBatch({
    required this.mediaIds,
    required this.storagePaths,
    required this.rejected,
  });

  final List<String> mediaIds;
  final List<String> storagePaths;
  final List<String> rejected;
}
