// Inline photo management on "My public profile". The thumbnail strip carries
// the add tile, drag-reorder and a NON-interactive star badge on the primary;
// the per-photo controls moved onto the opened hero image (a PageView): the
// set-primary star sits top-left and the delete (remove-from-public with undo)
// sits top-right, each acting on the photo currently shown in the hero. The
// last-photo guard blocks removing the final public photo. These capabilities
// migrated off the removed "Your photos" bottom sheet.
import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/screens/my_public_profile_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/photo_service.dart';
import 'package:ayma_flutter/widgets/inline_photo_carousel.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';

/// A [PhotoService] whose backend calls are recorded in-memory, so controller
/// behaviour can be tested without Firebase or the network.
class _FakePhotoService extends PhotoService {
  _FakePhotoService(this._grid, {this.batchResult, this.uploadError});

  final List<GridPhoto> _grid;
  final List<String> calls = [];
  PhotoUploadBatch? batchResult;
  Exception? uploadError;

  @override
  Future<List<GridPhoto>> loadGrid() async => List.of(_grid);

  @override
  Future<PhotoUploadBatch> uploadAndProcessAll(List<File> files) async {
    if (uploadError != null) throw uploadError!;
    return batchResult ??
        PhotoUploadBatch(
          mediaIds: files.map((f) => 'm_${f.path}').toList(),
          storagePaths: files.map((f) => 'p_${f.path}').toList(),
          rejected: const [],
        );
  }

  @override
  Future<void> remove(String mediaId) async => calls.add('remove:$mediaId');

  @override
  Future<void> setPrimary(String mediaId) async =>
      calls.add('primary:$mediaId');

  @override
  Future<void> reorder(List<String> mediaIds) async =>
      calls.add('reorder:${mediaIds.join(",")}');

  @override
  Future<void> deletePermanent(String mediaId) async =>
      calls.add('delete:$mediaId');
}

class _FakeImagePicker extends ImagePicker {
  _FakeImagePicker([this.files = const []]);
  final List<XFile> files;

  @override
  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    int? limit,
    bool requestFullMetadata = true,
  }) async => files;
}

GridPhoto _photo(String id) =>
    GridPhoto(mediaId: id, order: 0, downloadUrl: '');

Future<InlinePhotoController> _loaded(List<String> ids,
    {_FakePhotoService? svc}) async {
  final c = InlinePhotoController(
      service: svc ?? _FakePhotoService(ids.map(_photo).toList()));
  await c.load();
  return c;
}

void main() {
  // A tall, narrow surface so the square hero AND the thumbnail strip below it
  // both lay out on-screen (the default 800x600 surface pushes the strip off
  // the bottom, where its controls aren't hittable).
  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.physicalSize = const Size(400, 1600);
    b.platformDispatcher.views.first.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.platformDispatcher.views.first.resetPhysicalSize();
    b.platformDispatcher.views.first.resetDevicePixelRatio();
  });

  group('InlinePhotoController', () {
    test('load populates the grid', () async {
      final c = await _loaded(['a', 'b']);
      expect(c.photos.map((p) => p.mediaId), ['a', 'b']);
      expect(c.loading, isFalse);
    });

    test('removeFromPublic is optimistic and undo restores in place',
        () async {
      final svc = _FakePhotoService([_photo('a'), _photo('b'), _photo('c')]);
      final c = await _loaded([], svc: svc);
      c.removeFromPublic(c.photos[1]); // remove 'b'
      expect(c.photos.map((p) => p.mediaId), ['a', 'c']);
      expect(svc.calls, isEmpty); // backend write is deferred
      c.undoRemove();
      expect(c.photos.map((p) => p.mediaId), ['a', 'b', 'c']);
      expect(svc.calls, isEmpty); // undo needs no round-trip
    });

    test('setPrimary moves a photo to the front and calls the backend',
        () async {
      final svc = _FakePhotoService([_photo('a'), _photo('b'), _photo('c')]);
      final c = await _loaded([], svc: svc);
      await c.setPrimary(c.photos[2]); // make 'c' primary
      expect(c.photos.map((p) => p.mediaId), ['c', 'a', 'b']);
      expect(svc.calls, ['primary:c']);
    });

    test('reorder moves an item and persists the new order', () async {
      final svc = _FakePhotoService([_photo('a'), _photo('b'), _photo('c')]);
      final c = await _loaded([], svc: svc);
      await c.reorder(0, 2); // move 'a' to the end (onReorderItem convention)
      expect(c.photos.map((p) => p.mediaId), ['b', 'c', 'a']);
      expect(svc.calls, ['reorder:b,c,a']);
    });

    test('deletePermanent erases the photo and calls the backend', () async {
      final svc = _FakePhotoService([_photo('a'), _photo('b')]);
      final c = await _loaded([], svc: svc);
      final ok = await c.deletePermanent(c.photos[0]);
      expect(ok, isTrue);
      expect(c.photos.map((p) => p.mediaId), ['b']);
      expect(svc.calls, ['delete:a']);
    });

    test('pickAndAdd surfaces server moderation reason', () async {
      final picker = _FakeImagePicker([XFile('p1.jpg')]);
      final svc = _FakePhotoService(
        [],
        batchResult: const PhotoUploadBatch(
          mediaIds: [],
          storagePaths: [],
          rejected: ['screenshots of text are not allowed'],
        ),
      );
      final c = InlinePhotoController(service: svc, picker: picker);
      final msg = await c.pickAndAdd();
      expect(msg, 'That photo cannot be used - screenshots of text are not allowed.');
    });

    test('pickAndAdd humanizes capitalized sentence and adds trailing period', () async {
      final picker = _FakeImagePicker([XFile('p1.jpg')]);
      final svc = _FakePhotoService(
        [],
        batchResult: const PhotoUploadBatch(
          mediaIds: [],
          storagePaths: [],
          rejected: ['Screenshots of text are not allowed'],
        ),
      );
      final c = InlinePhotoController(service: svc, picker: picker);
      final msg = await c.pickAndAdd();
      expect(msg, 'That photo cannot be used - screenshots of text are not allowed.');
    });

    test('pickAndAdd suppresses internal codes and returns generic message', () async {
      final picker = _FakeImagePicker([XFile('p1.jpg')]);
      final svc = _FakePhotoService(
        [],
        batchResult: const PhotoUploadBatch(
          mediaIds: [],
          storagePaths: [],
          rejected: ['moderation_error'],
        ),
      );
      final c = InlinePhotoController(service: svc, picker: picker);
      final msg = await c.pickAndAdd();
      expect(msg, "That photo can't be used.");
    });

    test('pickAndAdd suppresses upload failed code and returns generic message', () async {
      final picker = _FakeImagePicker([XFile('p1.jpg')]);
      final svc = _FakePhotoService(
        [],
        batchResult: const PhotoUploadBatch(
          mediaIds: [],
          storagePaths: [],
          rejected: ['upload failed'],
        ),
      );
      final c = InlinePhotoController(service: svc, picker: picker);
      final msg = await c.pickAndAdd();
      expect(msg, "That photo can't be used.");
    });

    test('pickAndAdd catches upload exception and returns friendly message', () async {
      final picker = _FakeImagePicker([XFile('p1.jpg')]);
      final svc = _FakePhotoService(
        [],
        uploadError: const SocketException('connection reset'),
      );
      final c = InlinePhotoController(service: svc, picker: picker);
      final msg = await c.pickAndAdd();
      expect(msg, 'Upload failed. Please try again.');
    });
  });

  group('MyPublicProfileScreen inline carousel', () {
    MockClient mockHttp() => MockClient((request) async {
          if (request.url.path == '/explore/profile/u1') {
            return http.Response(
              jsonEncode({
                'uid': 'u1',
                'self': true,
                'blocked': false,
                'name': 'Sam',
                'age': 29,
                'location': 'Lisbon',
                'photos': ['https://example.com/p1.jpg'],
                'pages': [],
                'liked': false,
                'score': null,
                'thread_id': null,
                'has_chatted': false,
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8'
              },
            );
          }
          return http.Response(
            jsonEncode({
              'title': 'Story',
              'sections': const [],
              'meta': {'owner_uid': 'u1', 'viewer_can_edit': true},
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        });

    Future<InlinePhotoController> pumpScreen(
        WidgetTester tester, List<String> ids,
        {_FakePhotoService? svc}) async {
      final controller = InlinePhotoController(
          service: svc ?? _FakePhotoService(ids.map(_photo).toList()));
      await controller.load();
      final api = ApiClient(
          httpClient: mockHttp(), auth: MockFirebaseAuth(signedIn: true));
      await tester.pumpWidget(MaterialApp(
        home: MyPublicProfileScreen(
            myUid: 'u1', apiClient: api, photoController: controller),
      ));
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('shows the Add photo tile', (tester) async {
      await pumpScreen(tester, ['a', 'b']);
      expect(find.byKey(const ValueKey('inlinePhotoAddTile')), findsOneWidget);
    });

    testWidgets('the last public photo cannot be removed', (tester) async {
      final svc = _FakePhotoService([_photo('only')]);
      final c = await pumpScreen(tester, [], svc: svc);
      // The delete control now lives on the hero image (top-right) and acts on
      // the photo currently shown.
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      // No confirm dialog — a warning toast instead, and the photo stays.
      expect(find.text('Remove this photo?'), findsNothing);
      expect(
          find.textContaining('needs at least one photo'), findsOneWidget);
      expect(c.photos, hasLength(1));
      expect(svc.calls, isEmpty);
      await tester.pump(const Duration(seconds: 4)); // flush the toast timer
    });

    testWidgets('delete confirm removes from public, undo brings it back',
        (tester) async {
      final svc = _FakePhotoService([_photo('a'), _photo('b')]);
      final c = await pumpScreen(tester, [], svc: svc);
      // Hero opens on the primary (page 0); its top-right delete control opens
      // the confirm for the shown photo.
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Remove this photo?'), findsOneWidget);
      await tester.tap(find.text('Remove from public'));
      await tester.pumpAndSettle();
      expect(c.photos, hasLength(1));
      // Undo toast is up; tapping it restores the photo with no backend write.
      expect(find.text('Undo'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(c.photos, hasLength(2));
      expect(svc.calls, isEmpty);
    });

    testWidgets('tapping an outline star sets that photo primary',
        (tester) async {
      final svc = _FakePhotoService([_photo('a'), _photo('b')]);
      final c = await pumpScreen(tester, [], svc: svc);
      // The star now lives on the hero and acts on the photo currently shown.
      // At page 0 ('a') it is the filled "primary" star; bring 'b' into the
      // hero first by tapping its thumbnail, then its now-outline hero star
      // sets 'b' primary.
      await tester.tap(find.byKey(const ValueKey('inlinePhoto_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.star_outline_rounded));
      await tester.pumpAndSettle();
      expect(c.photos.first.mediaId, 'b');
      expect(svc.calls, ['primary:b']);
    });

    testWidgets('tapping Add photo displays moderation reason in warning toast',
        (tester) async {
      final picker = _FakeImagePicker([XFile('bad.jpg')]);
      final svc = _FakePhotoService(
        [_photo('a'), _photo('b')],
        batchResult: const PhotoUploadBatch(
          mediaIds: [],
          storagePaths: [],
          rejected: ['screenshots of text are not allowed'],
        ),
      );
      final controller = InlinePhotoController(service: svc, picker: picker);
      await controller.load();
      final api = ApiClient(
          httpClient: mockHttp(), auth: MockFirebaseAuth(signedIn: true));
      await tester.pumpWidget(MaterialApp(
        home: MyPublicProfileScreen(
            myUid: 'u1', apiClient: api, photoController: controller),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('inlinePhotoAddTile')));
      await tester.pumpAndSettle();

      expect(
        find.text('That photo cannot be used - screenshots of text are not allowed.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 4)); // flush toast timer
    });
  });
}
