import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../features/date_sim/date_sim_models.dart';

/// Live reads of a date simulation the backend is streaming into Firestore
/// (`users/{uid}/date_sims/{simId}` + its `messages` subcollection). The rules
/// make these owner-read-only; the client never writes them.
class DateSimService {
  DateSimService({FirebaseAuth? auth, FirebaseFirestore? firestore})
    : _auth = auth ?? FirebaseAuth.instance,
      _fsOverride = firestore;

  final FirebaseAuth _auth;
  final FirebaseFirestore? _fsOverride;

  FirebaseFirestore get _db => _fsOverride ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _sim(String simId) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('No signed-in user.');
    return _db.collection('users').doc(uid).collection('date_sims').doc(simId);
  }

  /// The sim's status/verdict doc; emits null until the backend creates it.
  Stream<DateSimDoc?> watchSim(String simId) =>
      _sim(simId)
          .snapshots()
          .map((s) => s.exists ? DateSimDoc.fromMap(s.data()!) : null);

  /// The transcript so far, in order, re-emitted as each message lands.
  Stream<List<DateSimMessage>> watchMessages(String simId) => _sim(simId)
      .collection('messages')
      .orderBy('seq')
      .snapshots()
      .map((q) => q.docs.map((d) => DateSimMessage.fromMap(d.data())).toList());
}
