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

  /// Upload [file] to `uploads/{uid}/…` and run the §8.5 pipeline. The caller
  /// checks [MediaResult.published] before calling [addToGrid].
  Future<MediaResult> uploadAndProcess(File file) async {
    final ext = file.path.contains('.')
        ? file.path.substring(file.path.lastIndexOf('.'))
        : '.jpg';
    final path =
        'uploads/$_uid/photo_${DateTime.now().millisecondsSinceEpoch}$ext';
    await _storage.ref(path).putFile(file);
    return _api.registerMedia(path, context: 'profile');
  }

  Future<void> addToGrid(String mediaId) => _api.addPhoto(mediaId);

  Future<void> remove(String mediaId) => _api.removePhoto(mediaId);

  Future<void> reorder(List<String> mediaIds) => _api.reorderPhotos(mediaIds);

  Future<String> instagramAuthUrl() => _api.instagramAuthUrl();

  Future<int> instagramConnect(String code) => _api.instagramConnect(code);

  Future<void> instagramDisconnect() => _api.instagramDisconnect();
}
