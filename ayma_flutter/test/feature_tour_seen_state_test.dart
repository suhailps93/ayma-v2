import 'package:ayma_flutter/services/feature_tour_store.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

/// Per-user seen-state persists on `users/{uid}/profile/main.seen_tour_features`
/// and round-trips through [ProfileService] / [FeatureTourStore] (§11.2).
ProfileService _profiles(FakeFirebaseFirestore db) => ProfileService(
      auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')),
      firestore: db,
    );

void main() {
  test('seen features round-trip and arrayUnion accumulates', () async {
    final db = FakeFirebaseFirestore();
    final p = _profiles(db);

    expect(await p.readSeenTourFeatures(), isEmpty);

    await p.markTourFeaturesSeen(['voice_dating', 'privacy']);
    expect(await p.readSeenTourFeatures(), {'voice_dating', 'privacy'});

    // A later spotlight marks a new id — the old ones are kept (arrayUnion).
    await p.markTourFeaturesSeen(['privacy', 'date_sim']);
    expect(await p.readSeenTourFeatures(),
        {'voice_dating', 'privacy', 'date_sim'});
  });

  test('marking an empty set is a no-op (no write)', () async {
    final db = FakeFirebaseFirestore();
    final p = _profiles(db);
    await p.markTourFeaturesSeen(const []);
    final snap = await db.doc('users/me/profile/main').get();
    expect(snap.exists, isFalse);
  });

  test('reset clears the seen set', () async {
    final db = FakeFirebaseFirestore();
    final p = _profiles(db);
    await p.markTourFeaturesSeen(['a', 'b']);
    expect(await p.readSeenTourFeatures(), {'a', 'b'});

    await p.resetTourFeatures();
    expect(await p.readSeenTourFeatures(), isEmpty);
  });

  test('markTourFeaturesSeen never clobbers other profile fields', () async {
    final db = FakeFirebaseFirestore();
    await db.doc('users/me/profile/main').set({'name': 'Sam', 'paused': true});
    final p = _profiles(db);

    await p.markTourFeaturesSeen(['voice_dating']);
    final data = (await db.doc('users/me/profile/main').get()).data()!;
    expect(data['name'], 'Sam');
    expect(data['paused'], true);
    expect(data['seen_tour_features'], ['voice_dating']);
  });

  test('FeatureTourStore delegates to the profile service', () async {
    final db = FakeFirebaseFirestore();
    final store = FeatureTourStore(profiles: _profiles(db));

    expect(await store.loadSeen(), isEmpty);
    await store.markSeen(['voice_dating']);
    expect(await store.loadSeen(), {'voice_dating'});
    await store.reset();
    expect(await store.loadSeen(), isEmpty);
  });

  test('removing an id via arrayRemove unsees only that feature', () async {
    final db = FakeFirebaseFirestore();
    final store = FeatureTourStore(profiles: _profiles(db));

    await store.markSeen(['voice_dating', 'async_voice']);
    expect(await store.loadSeen(), {'voice_dating', 'async_voice'});

    // Unsee async_voice via arrayRemove (the exact reset_tour / triage operation)
    await db.doc('users/me/profile/main').update({
      'seen_tour_features': FieldValue.arrayRemove(['async_voice']),
    });
    expect(await store.loadSeen(), {'voice_dating'});
  });

  test('loadSeen swallows storage errors and returns empty (shows the tour)',
      () async {
    // No Firebase at all → ProfileService throws; the store must default to
    // "not seen" rather than propagating.
    final store = FeatureTourStore();
    expect(await store.loadSeen(), isEmpty);
  });
}
