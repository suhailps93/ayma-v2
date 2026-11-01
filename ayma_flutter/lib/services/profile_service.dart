import 'dart:io';
import 'dart:ui' show Color;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'age_gate.dart';
import 'api_client.dart' show kInteractiveTimeout;

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

  /// Uploads a verification selfie to `verification/{uid}/selfie{ext}` — a
  /// storage path deliberately distinct from `uploads/` (chat attachments)
  /// and the profile-media grid. Never referenced by any profile / gallery /
  /// Explore-facing code path; used only by `POST /verification/selfie` to
  /// seed the account's face-match reference (§ face verification). A fixed
  /// filename so re-verifying overwrites rather than accumulates.
  Future<String> uploadVerificationSelfie(File file) async {
    final ref = _storage.ref('verification/$_uid/selfie${_extension(file.path)}');
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
    final snap = await _profileDoc.get().timeout(kInteractiveTimeout);
    final data = snap.data();
    return data == null ? null : ProfileData.fromMap(data);
  }

  /// Live profile updates — the voice-driven preboarding screen autofills its
  /// fields as Ayma's `set_profile_field` tool writes them (§4.2, Step 31).
  Stream<ProfileData?> watchProfile() => _profileDoc.snapshots().map(
        (snap) => snap.data() == null
            ? null
            : ProfileData.fromMap(snap.data()!),
      );

  /// Post-onboarding edit of the structured fields (§4.5). Only the keys passed
  /// are touched; `ai_body` and other documents are never involved.
  ///
  /// [firstName] / [lastName] / [phone] are the identity fields the web-search
  /// skill needs — separate from [name] (the display name).
  Future<void> updateStructuredFields({
    String? name,
    String? firstName,
    String? lastName,
    String? phone,
    DateTime? birthdate,
    String? gender,
    List<String>? interestedIn,
    String? location,
  }) {
    final update = <String, dynamic>{
      'updated_at': FieldValue.serverTimestamp(),
    };
    if (name != null) update['name'] = name.trim();
    if (firstName != null) update['first_name'] = firstName.trim();
    if (lastName != null) update['last_name'] = lastName.trim();
    if (phone != null) update['phone'] = _normalisePhone(phone);
    if (birthdate != null) update['birthdate'] = _birthdateStamp(birthdate);
    if (gender != null) update['gender'] = gender;
    if (interestedIn != null) update['interested_in'] = interestedIn;
    if (location != null) update['location'] = location.trim();
    return _profileDoc.set(update, SetOptions(merge: true));
  }

  /// Writes the structured preboarding fields (§4.2). Merges so later edits
  /// (§4.5) don't clobber other keys. The photo lands on the `photos` grid via
  /// the server pipeline (`/media` -> `/media/photos`), not here — `photos` is
  /// backend-authored (§9.2).
  Future<void> savePreboarding({
    required String name,
    required DateTime birthdate,
    required String gender,
    required List<String> interestedIn,
    required String location,
    required String photoStoragePath,
    String firstName = '',
    String lastName = '',
    String phone = '',
  }) {
    final birthdateStamp = _birthdateStamp(birthdate);
    return _profileDoc.set({
      'name': name.trim(),
      if (firstName.trim().isNotEmpty) 'first_name': firstName.trim(),
      if (lastName.trim().isNotEmpty) 'last_name': lastName.trim(),
      if (_normalisePhone(phone).isNotEmpty) 'phone': _normalisePhone(phone),
      'birthdate': birthdateStamp,
      'gender': gender,
      'interested_in': interestedIn,
      'location': location.trim(),
      'updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// A birthdate as a Firestore timestamp. Refuses under-18 dates (the
  /// server and `firestore.rules` do too) and stores local noon, so the UTC
  /// calendar date the server reads is the date the person picked in any
  /// timezone.
  static Timestamp _birthdateStamp(DateTime birthdate) {
    if (!AgeGate.isAdult(birthdate)) throw const UnderageBirthdateException();
    return Timestamp.fromDate(
      DateTime(birthdate.year, birthdate.month, birthdate.day, 12),
    );
  }

  /// Keep digits and a leading `+`; cap at 32 chars (mirrors the backend
  /// `set_profile_field` rule).
  static String _normalisePhone(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final plus = trimmed.startsWith('+') ? '+' : '';
    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    final out = '$plus$digits';
    return out.length <= 32 ? out : out.substring(0, 32);
  }

  /// The current "Pause matching" state (§14.2).
  Stream<bool> watchPaused() =>
      _profileDoc.snapshots().map((s) => s.data()?['paused'] == true);

  /// Toggle "Pause matching" — a paused user drops out of Explore and match
  /// candidate sourcing (§14.2).
  Future<void> setPaused(bool paused) {
    return _profileDoc.set(
      {'paused': paused, 'updated_at': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  /// Sets `ayma_voice_name` (§13.3). Takes effect from the next voice session.
  Future<void> setVoicePreference(String presetName) {
    return _profileDoc.set(
      {'ayma_voice_name': presetName, 'updated_at': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  /// Sets `ayma_voice_language` — the default accent/language Ayma speaks
  /// (§13.3). Takes effect from the next voice session; mid-call, Ayma still
  /// follows the caller into another language.
  Future<void> setVoiceLanguage(String code) {
    return _profileDoc.set(
      {
        'ayma_voice_language': code,
        'updated_at': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  /// Mirrors the chosen accent colour (§ Accent Color settings) onto
  /// `ayma_accent_color` as a `#RRGGBB` hex string, so it follows the user
  /// across devices/reinstalls the same way `ayma_voice_name` does — local
  /// `SharedPreferences` (via `AccentColorController`) stays the fast path
  /// that paints the very next frame; this is the durable copy.
  Future<void> setAccentColor(Color color) {
    return _profileDoc.set(
      {
        'ayma_accent_color': _toHex(color),
        'updated_at': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  /// One-shot read of the server-side accent colour (`null` if never set,
  /// signed out, or the read fails) — used only on first local launch
  /// (`AccentColorController.load()`) to pick up a colour chosen on another
  /// device/before a reinstall; every later change flows the other
  /// direction, local pick -> [setAccentColor].
  Future<Color?> getAccentColor() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;
    final snap = await _profileDoc.get().timeout(kInteractiveTimeout);
    final hex = snap.data()?['ayma_accent_color'] as String?;
    return hex == null ? null : _fromHex(hex);
  }

  static String _toHex(Color c) {
    final argb = c.toARGB32();
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  static Color? _fromHex(String hex) {
    final cleaned = hex.replaceFirst('#', '');
    final rgb = int.tryParse(cleaned, radix: 16);
    if (rgb == null || cleaned.length != 6) return null;
    return Color(0xFF000000 | rgb);
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
    this.firstName = '',
    this.lastName = '',
    this.phone = '',
    this.partnerAgeMin,
    this.partnerAgeMax,
    this.distancePreference = '',
  });

  final String name;
  final String firstName;
  final String lastName;
  final String phone;
  final DateTime? birthdate;
  final String gender;
  final List<String> interestedIn;
  final String location;

  /// Partner age range and distance preference — the questionnaire answers
  /// matching reads, mirrored on the profile doc as `qz_*`.
  final int? partnerAgeMin;
  final int? partnerAgeMax;
  final String distancePreference;

  /// "First Last" from the identity fields, falling back to the display name.
  String get fullName {
    final joined = [firstName, lastName]
        .where((p) => p.trim().isNotEmpty)
        .join(' ')
        .trim();
    return joined.isNotEmpty ? joined : name;
  }

  factory ProfileData.fromMap(Map<String, dynamic> map) {
    final bd = map['birthdate'];
    return ProfileData(
      name: (map['name'] as String?) ?? '',
      firstName: (map['first_name'] as String?) ?? '',
      lastName: (map['last_name'] as String?) ?? '',
      phone: (map['phone'] as String?) ?? '',
      birthdate: bd is Timestamp ? bd.toDate() : null,
      gender: (map['gender'] as String?) ?? '',
      interestedIn:
          ((map['interested_in'] as List?)?.cast<String>()) ?? const [],
      location: (map['location'] as String?) ?? '',
      partnerAgeMin: (map['qz_partner_age_min'] as num?)?.toInt(),
      partnerAgeMax: (map['qz_partner_age_max'] as num?)?.toInt(),
      distancePreference: (map['distance_pref'] as String?) ?? '',
    );
  }
}
