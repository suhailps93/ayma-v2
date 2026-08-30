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
        _firestoreOverride = firestore,
        _storageOverride = storage;

  final FirebaseAuth _auth;
  final FirebaseFirestore? _firestoreOverride;
  final FirebaseStorage? _storageOverride;

  // Lazy so a test subclass that overrides the data methods never trips over
  // `FirebaseFirestore.instance` before `Firebase.initializeApp()`.
  FirebaseFirestore get _firestore =>
      _firestoreOverride ?? FirebaseFirestore.instance;
  FirebaseStorage get _storage => _storageOverride ?? FirebaseStorage.instance;

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

  /// Records the "get started" transition on `users/{uid}` so the server can
  /// derive `session_mode: interview` for a still-anonymous session (§3.3).
  Future<void> markOnboardingStarted() {
    return _firestore.doc('users/$_uid').set(
      {'onboarding_started': true, 'updated_at': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  /// The structured profile document, or `null` before onboarding writes it.
  Future<ProfileData?> readProfile() async {
    final snap = await _profileDoc.get();
    final data = snap.data();
    return data == null ? null : ProfileData.fromMap(data);
  }

  /// Post-onboarding edit of the structured fields (§4.5). Only the keys passed
  /// are touched; `ai_body` and other documents are never involved.
  Future<void> updateStructuredFields({
    String? name,
    DateTime? birthdate,
    String? gender,
    List<String>? interestedIn,
    String? location,
  }) {
    final update = <String, dynamic>{
      'updated_at': FieldValue.serverTimestamp(),
    };
    if (name != null) update['name'] = name.trim();
    if (birthdate != null) update['birthdate'] = Timestamp.fromDate(birthdate);
    if (gender != null) update['gender'] = gender;
    if (interestedIn != null) update['interested_in'] = interestedIn;
    if (location != null) update['location'] = location.trim();
    return _profileDoc.set(update, SetOptions(merge: true));
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

/// Read model for the structured profile document.
class ProfileData {
  const ProfileData({
    required this.name,
    required this.birthdate,
    required this.gender,
    required this.interestedIn,
    required this.location,
  });

  final String name;
  final DateTime? birthdate;
  final String gender;
  final List<String> interestedIn;
  final String location;

  factory ProfileData.fromMap(Map<String, dynamic> map) {
    final bd = map['birthdate'];
    return ProfileData(
      name: (map['name'] as String?) ?? '',
      birthdate: bd is Timestamp ? bd.toDate() : null,
      gender: (map['gender'] as String?) ?? '',
      interestedIn:
          ((map['interested_in'] as List?)?.cast<String>()) ?? const [],
      location: (map['location'] as String?) ?? '',
    );
  }
}
