import 'package:ayma_flutter/screens/photo_management_screen.dart';
import 'package:ayma_flutter/services/photo_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePhotos extends PhotoService {
  _FakePhotos(this._grid)
      : super(auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')));

  List<GridPhoto> _grid;
  final List<String> removed = [];
  List<String>? reordered;

  @override
  Future<List<GridPhoto>> loadGrid() async => _grid;

  @override
  Future<void> remove(String mediaId) async {
    removed.add(mediaId);
    _grid = _grid.where((p) => p.mediaId != mediaId).toList();
  }

  @override
  Future<void> reorder(List<String> mediaIds) async => reordered = mediaIds;
}

GridPhoto _p(String id, int order) => GridPhoto(
      mediaId: id,
      order: order,
      // 1x1 transparent PNG data URI so Image.network has something to decode.
      downloadUrl:
          'https://example.invalid/$id.png',
    );

void main() {
  testWidgets('lists photos, marks the first primary, removes softly',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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
}
