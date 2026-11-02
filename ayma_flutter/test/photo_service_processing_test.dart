// R2-C3: a newly-added profile photo must resolve from "Processing…" to
// displayed, and a server-persisted photo must survive an app relaunch.
//
// Both symptoms share one client defect: PhotoService.loadGrid used to drop a
// photo that `GET /media/photos` already lists the instant its download URL
// didn't resolve (the just-uploaded doc/object lags the list it is already in,
// or a cold Firestore/Storage read transiently fails) — with no retry. So a
// just-added photo never appeared, and on relaunch a persisted photo vanished.
//
// These tests drive the retry through the `downloadUrlFor` seam (so no live
// Storage backend is needed) with a MockClient feeding the server photo list.
import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/photo_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A [PhotoService] whose per-photo URL resolution is scripted: a mediaId
/// resolves (returns a URL) only on/after its [resolveOnAttempt] call,
/// returning null before that — modelling the read-your-writes / cold-read
/// race that [PhotoService.loadGrid] must now retry instead of dropping.
class _RacingPhotoService extends PhotoService {
  _RacingPhotoService({
    required ApiClient api,
    required FirebaseAuth auth,
    required this.resolveOnAttempt,
  }) : super(api: api, auth: auth);

  /// mediaId -> the 1-based attempt on which its URL first resolves (default 1).
  final Map<String, int> resolveOnAttempt;
  final Map<String, int> _calls = {};

  @override
  Future<String?> downloadUrlFor(String mediaId) async {
    final n = _calls[mediaId] = (_calls[mediaId] ?? 0) + 1;
    return n >= (resolveOnAttempt[mediaId] ?? 1)
        ? 'https://cdn.test/$mediaId.jpg'
        : null;
  }
}

/// ApiClient whose `GET /media/photos` returns [entries] (the authoritative,
/// server-persisted grid), with a MockFirebaseAuth-signed-in user so headers
/// resolve offline.
ApiClient _apiListing(List<Map<String, dynamic>> entries) => ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/media/photos')) {
          return http.Response(jsonEncode({'photos': entries}), 200);
        }
        return http.Response('{}', 200);
      }),
    );

void main() {
  group('loadGrid does not drop a server-listed photo on a transient miss', () {
    test('(i) a just-added photo that resolves only on the 2nd attempt still '
        'appears (not stuck on Processing)', () async {
      final svc = _RacingPhotoService(
        api: _apiListing([
          {'media_id': 'existing', 'order': 0},
          {'media_id': 'justAdded', 'order': 1},
        ]),
        auth: MockFirebaseAuth(signedIn: true),
        // The brand-new photo's URL isn't resolvable on the first pass.
        resolveOnAttempt: {'justAdded': 2},
      );

      final grid = await svc.loadGrid();

      expect(grid.map((g) => g.mediaId), ['existing', 'justAdded'],
          reason: 'the new photo must not be dropped while it is still '
              'propagating — loadGrid retries the unresolved entry');
    });

    test('(ii) on (re)load a persisted photo whose read fails twice still '
        'renders in server order (not dropped on relaunch)', () async {
      final svc = _RacingPhotoService(
        api: _apiListing([
          {'media_id': 'a', 'order': 0},
          {'media_id': 'b', 'order': 1},
          {'media_id': 'c', 'order': 2},
        ]),
        auth: MockFirebaseAuth(signedIn: true),
        // 'b' is persisted on the server but its client read is cold/slow,
        // resolving only on the 3rd attempt.
        resolveOnAttempt: {'b': 3},
      );

      final grid = await svc.loadGrid();

      expect(grid.map((g) => g.mediaId), ['a', 'b', 'c'],
          reason: 'a server-persisted photo must survive relaunch even when '
              'its first client reads fail');
    });

    test('a photo that never resolves within the retry budget is omitted '
        'without blocking the ones that do', () async {
      final svc = _RacingPhotoService(
        api: _apiListing([
          {'media_id': 'good', 'order': 0},
          {'media_id': 'gone', 'order': 1},
        ]),
        auth: MockFirebaseAuth(signedIn: true),
        resolveOnAttempt: {'gone': 99}, // never within the bounded retries
      );

      final grid = await svc.loadGrid();

      expect(grid.map((g) => g.mediaId), ['good']);
    });
  });
}
