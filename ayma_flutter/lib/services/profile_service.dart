import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Structured onboarding profile, one of the three per-user documents (§3.2).
///
/// The architecture writes it as a single document at `users/{uid}/profile`;
/// Firestore needs an id for that sub-document, so it lives at
/// `users/{uid}/profile/main`.
class ProfileService {
  ProfileService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;

  String get _uid {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('No signed-in user.');
    return uid;
  }

  DocumentReference<Map<String, dynamic>> get _profileDoc =>
      _firestore.doc('users/$_uid/profile/main');

  /// Uploads a preboarding photo to `uploads/{uid}/{filename}` (§4.4) and
  /// returns its storage path. The face-embedding pipeline (§2.5) is wired
  /// separately in Step 30.
  Future<String> uploadProfilePhoto(File file) async {
    final filename = 'profile_${DateTime.now().millisecondsSinceEpoch}'
        '${_extension(file.path)}';
    final ref = _storage.ref('uploads/$_uid/$filename');
    await ref.putFile(file);
    return ref.fullPath;
  }

  /// Writes the six structured preboarding fields (§4.2). Merges so later edits
  /// (§4.5) don't clobber other keys.
  Future<void> savePreboarding({
    required String name,
    required DateTime birthdate,
    required String gender,
    required List<String> interestedIn,
    required String location,
    required String photoStoragePath,
  }) {
    return _profileDoc.set({
      'name': name.trim(),
      'birthdate': Timestamp.fromDate(birthdate),
      'gender': gender,
      'interested_in': interestedIn,
      'location': location.trim(),
      'photos': [
        {'storage_path': photoStoragePath, 'order': 0},
      ],
      'updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot == -1 ? '.jpg' : path.substring(dot);
  }
}
