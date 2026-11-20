import 'package:ayma_flutter/screens/public_profile_edit_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake backend for the public-only editor: a canned `profileBullets` payload
/// and a captured `profileBulletsSave`.
class _FakeApi extends ApiClient {
  _FakeApi(this._sections) : super(auth: MockFirebaseAuth(signedIn: true));

  final List<BulletSection> _sections;
  final List<(String, List<StoryBullet>)> saves = [];

  @override
  Future<List<BulletSection>> profileBullets() async => _sections;

  @override
  Future<void> profileBulletsSave(String pageId, List<StoryBullet> bullets) async {
    saves.add((pageId, bullets));
  }
}

BulletSection _section(
  String pageType,
  String title,
  String pageId,
  List<StoryBullet> bullets, {
  int order = 0,
}) =>
    BulletSection(
      pageType: pageType,
      title: title,
      pageId: pageId,
      order: order,
      bullets: bullets,
    );

StoryBullet _b(String id, String text, String visibility) =>
    StoryBullet(id: id, text: text, visibility: visibility);

Future<void> _pump(WidgetTester tester, _FakeApi api) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: AymaTheme.light,
    home: PublicProfileEditScreen(api: api),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows only PUBLIC bullets, grouped by section; private and '
      'Ayma-only never appear', (tester) async {
    final api = _FakeApi([
      _section('values', 'Values & beliefs', 'values', [
        _b('v1', 'Kindness over cleverness', 'public'),
        _b('v2', 'A private value only Ayma sees', 'private'),
      ], order: 1),
      _section('goals', 'Life goals', 'goals', [
        _b('g1', 'Build something that outlasts me', 'public'),
      ], order: 2),
      // No public bullet → this whole section must be absent from the view.
      _section('finances', 'Money & security', 'finances', [
        _b('f1', 'A private money note', 'private'),
      ], order: 3),
    ]);

    await _pump(tester, api);

    // Public content + its section headers are shown.
    expect(find.text('Kindness over cleverness'), findsOneWidget);
    expect(find.text('Build something that outlasts me'), findsOneWidget);
    expect(find.text('Values & beliefs'), findsOneWidget);
    expect(find.text('Life goals'), findsOneWidget);
    // Private content and a wholly-private section never appear.
    expect(find.text('A private value only Ayma sees'), findsNothing);
    expect(find.text('Money & security'), findsNothing);
    expect(find.text('A private money note'), findsNothing);
  });

  testWidgets('editing a bullet + adding a note saves public (edited + new) and '
      're-sends the private bullet unchanged (same node, nothing dropped)',
      (tester) async {
    final api = _FakeApi([
      _section('values', 'Values & beliefs', 'values', [
        _b('v1', 'Old public value', 'public'),
        _b('v2', 'Kept private', 'private'),
      ], order: 1),
    ]);

    await _pump(tester, api);

    // Edit the public bullet in place.
    await tester.enterText(
        find.widgetWithText(TextField, 'Old public value'), 'New public value');
    // Add a new public note in this section and type into it.
    await tester.tap(find.byKey(const ValueKey('addNote_values')));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.last, 'A brand new public note');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('publicEditSave')));
    await tester.pumpAndSettle();

    expect(api.saves, hasLength(1));
    final (pageId, bullets) = api.saves.single;
    expect(pageId, 'values');
    // Order preserved: edited public (id kept), private (kept verbatim), then
    // the appended new public note (empty id = a new node).
    expect(bullets.map((b) => b.text).toList(),
        ['New public value', 'Kept private', 'A brand new public note']);
    expect(bullets.map((b) => b.visibility).toList(),
        ['public', 'private', 'public']);
    expect(bullets.map((b) => b.id).toList(), ['v1', 'v2', '']);
  });

  testWidgets('a removed public bullet is dropped on save; the private bullet '
      'still survives', (tester) async {
    final api = _FakeApi([
      _section('values', 'Values & beliefs', 'values', [
        _b('v1', 'Remove me', 'public'),
        _b('v2', 'Kept private', 'private'),
      ], order: 1),
    ]);

    await _pump(tester, api);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.close).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('publicEditSave')));
    await tester.pumpAndSettle();

    final (_, bullets) = api.saves.single;
    expect(bullets.map((b) => b.text).toList(), ['Kept private']);
    expect(bullets.single.visibility, 'private');
  });

  testWidgets('Save stays disabled until an edit, and an unchanged save writes '
      'nothing', (tester) async {
    final api = _FakeApi([
      _section('values', 'Values & beliefs', 'values',
          [_b('v1', 'Unchanged', 'public')], order: 1),
    ]);

    await _pump(tester, api);

    final save = tester.widget<TextButton>(
        find.byKey(const ValueKey('publicEditSave')));
    expect(save.onPressed, isNull); // disabled with no edits
    expect(api.saves, isEmpty);
  });
}
