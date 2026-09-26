import 'dart:io';

import 'package:ayma_flutter/screens/photo_management_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/photo_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

class _FakePhotos extends PhotoService {
  _FakePhotos(this._grid)
      : super(auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')));

  List<GridPhoto> _grid;
  final List<String> removed = [];
  List<String>? reordered;

  /// Files handed to the last [uploadAndProcessAll] call, in order.
  List<File>? uploadedFiles;

  /// Media ids handed to the last [addToGridBatch] call.
  List<String>? batchedMediaIds;

  /// Storage paths handed to the last [rescanWebSearchPhotos] call.
  List<String>? rescannedPaths;

  /// media ids in [uploadAndProcessAll] that should be reported as rejected
  /// (moderation failure) instead of uploaded.
  Set<String> rejectFileNames = const {};

  @override
  Future<List<GridPhoto>> loadGrid() async => _grid;

  @override
  Future<PhotoUploadBatch> uploadAndProcessAll(List<File> files) async {
    uploadedFiles = files;
    final mediaIds = <String>[];
    final storagePaths = <String>[];
    final rejected = <String>[];
    for (final f in files) {
      final name = f.path.split('/').last;
      if (rejectFileNames.contains(name)) {
        rejected.add("can't be used");
      } else {
        mediaIds.add('media_$name');
        storagePaths.add('uploads/me/$name');
      }
    }
    return PhotoUploadBatch(
        mediaIds: mediaIds, storagePaths: storagePaths, rejected: rejected);
  }

  @override
  Future<PhotoBatchResult> addToGridBatch(List<String> mediaIds) async {
    batchedMediaIds = mediaIds;
    _grid = [
      ..._grid,
      for (var i = 0; i < mediaIds.length; i++)
        GridPhoto(
          mediaId: mediaIds[i],
          order: _grid.length + i,
          downloadUrl: 'https://example.invalid/${mediaIds[i]}.png',
        ),
    ];
    return PhotoBatchResult(photos: const [], added: mediaIds, failed: const []);
  }

  @override
  Future<void> rescanWebSearchPhotos(List<String> storagePaths) async {
    rescannedPaths = storagePaths;
  }

  @override
  Future<void> remove(String mediaId) async {
    removed.add(mediaId);
    _grid = _grid.where((p) => p.mediaId != mediaId).toList();
  }

  @override
  Future<void> reorder(List<String> mediaIds) async => reordered = mediaIds;
}

/// An [ImagePicker] whose [pickMultiImage] returns a canned list of files
/// instead of opening a real platform picker.
class _FakePicker extends ImagePicker {
  _FakePicker(this._paths);

  final List<String> _paths;

  @override
  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    int? limit,
    bool requestFullMetadata = true,
  }) async =>
      _paths.map((p) => XFile(p)).toList();
}

GridPhoto _p(String id, int order) => GridPhoto(
      mediaId: id,
      order: order,
      // 1x1 transparent PNG data URI so Image.network has something to decode.
      downloadUrl:
          'https://example.invalid/$id.png',
    );

Widget _app(PhotoService svc, {ImagePicker? picker}) {
  final router = GoRouter(
    initialLocation: PhotoManagementScreen.path,
    routes: [
      GoRoute(
        path: PhotoManagementScreen.path,
        builder: (_, __) => PhotoManagementScreen(
          service: svc,
          picker: picker,
        ),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  void bigView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('lists photos, marks the first primary, removes softly',
      (tester) async {
    bigView(tester);
    final svc = _FakePhotos([_p('m1', 0), _p('m2', 1)]);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: PhotoManagementScreen(service: svc),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Primary photo'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    expect(svc.removed, ['m1']);
  });

  testWidgets('empty grid shows the hint', (tester) async {
    final svc = _FakePhotos(const []);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: PhotoManagementScreen(service: svc),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('No photos yet'), findsOneWidget);
  });

  testWidgets(
      'picking several photos at once batches them into one grid add and '
      'queues a rescan', (tester) async {
    bigView(tester);
    final svc = _FakePhotos([_p('m1', 0)]);
    final picker = _FakePicker(['/tmp/a.jpg', '/tmp/b.jpg']);
    await tester.pumpWidget(_app(svc, picker: picker));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add photo'));
    await tester.pumpAndSettle();

    expect(svc.uploadedFiles?.length, 2);
    expect(svc.batchedMediaIds, ['media_a.jpg', 'media_b.jpg']);
    expect(svc.rescannedPaths,
        ['uploads/me/a.jpg', 'uploads/me/b.jpg']);
    // The grid reloads and now shows the newly added photos too.
    expect(svc.reordered, isNull); // unaffected by the add
  });

  testWidgets('photos that fail moderation are reported, not added',
      (tester) async {
    bigView(tester);
    final svc = _FakePhotos([_p('m1', 0)])
      ..rejectFileNames = {'bad.jpg'};
    final picker = _FakePicker(['/tmp/good.jpg', '/tmp/bad.jpg']);
    await tester.pumpWidget(_app(svc, picker: picker));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add photo'));
    await tester.pumpAndSettle();

    expect(svc.batchedMediaIds, ['media_good.jpg']);
    expect(find.textContaining('1 photo could not be added'), findsOneWidget);
  });
}
