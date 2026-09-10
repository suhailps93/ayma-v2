import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/screens/dm_thread_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/dm_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A stub ApiClient whose `/profiles/mini` returns [profiles] keyed by uid.
ApiClient _api([Map<String, Map<String, dynamic>> profiles = const {}]) {
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/profiles/mini') {
        return http.Response(jsonEncode({'profiles': profiles}), 200);
      }
      return http.Response('{}', 200);
    }),
  );
}

class _FakeDm extends DmService {
  _FakeDm(this._msgs, {this.chips = const []})
      : super(auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')));

  final StreamController<List<DmMessage>> _msgs;
  final List<String> sent = [];
  final List<String> blocked = [];
  final List<String> chips;
  final List<File> uploaded = [];
  final List<({String type, String caption})> attachmentsSent = [];

  @override
  Stream<List<DmMessage>> watchMessages(String threadId) => _msgs.stream;

  @override
  Future<List<String>> icebreakers(String threadId) async => chips;

  @override
  Future<void> block(String otherUid) async => blocked.add(otherUid);

  @override
  Future<void> sendText(String threadId, String text) async {
    sent.add(text);
    _msgs.add([
      DmMessage(
        id: 'x',
        senderUid: 'me',
        type: 'text',
        body: text,
        createdAt: DateTime.now(),
      ),
    ]);
  }

  @override
  Future<DmAttachment> uploadAttachment(File file,
      {required String threadId}) async {
    uploaded.add(file);
    return const DmAttachment(
      storagePath: 'uploads/me/dm/a__me/1.jpg',
      downloadUrl: 'https://example.invalid/1.jpg',
      contentType: 'image/jpeg',
      sizeBytes: 1234,
      name: '1.jpg',
    );
  }

  @override
  Future<void> sendAttachment(String threadId,
      {required String type,
      required DmAttachment attachment,
      String caption = ''}) async {
    attachmentsSent.add((type: type, caption: caption));
  }
}

void main() {
  testWidgets('renders bubbles by type and sends text', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(home: DmThreadScreen(threadId: 'a__me', dmService: dm, apiClient: _api())),
    );
    await tester.pump();

    ctrl.add([
      DmMessage(id: '1', senderUid: 'a', type: 'text', body: 'hey', createdAt: DateTime.now()),
      DmMessage(id: '2', senderUid: 'a', type: 'shared_profile', body: 'c', createdAt: DateTime.now()),
      DmMessage(id: '3', senderUid: 'me', type: 'photo', body: 'uploads/me/p.jpg', createdAt: DateTime.now()),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('hey'), findsOneWidget);
    expect(find.text('👤 Shared a profile'), findsOneWidget);
    expect(find.text('📷 Photo'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'yo');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(dm.sent, ['yo']);
    expect(find.text('yo'), findsOneWidget);
  });

  testWidgets('renders an image attachment as a tappable thumbnail with caption',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(home: DmThreadScreen(threadId: 'a__me', dmService: dm)),
    );
    await tester.pump();
    ctrl.add([
      DmMessage(
        id: 'i1',
        senderUid: 'a',
        type: 'image',
        body: 'sunset',
        createdAt: DateTime.now(),
        attachmentUrl: 'https://example.invalid/i1.jpg',
        attachmentPath: 'uploads/a/dm/a__me/i1.jpg',
        mime: 'image/jpeg',
        fileName: 'i1.jpg',
        size: 4096,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsWidgets);
    expect(find.text('sunset'), findsOneWidget);

    // Tap the thumbnail -> full-screen viewer with a close button.
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('renders a file attachment as a name + size row', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(home: DmThreadScreen(threadId: 'a__me', dmService: dm)),
    );
    await tester.pump();
    ctrl.add([
      DmMessage(
        id: 'f1',
        senderUid: 'me',
        type: 'file',
        body: '',
        createdAt: DateTime.now(),
        attachmentUrl: 'https://example.invalid/report.pdf',
        attachmentPath: 'uploads/me/dm/a__me/report.pdf',
        mime: 'application/pdf',
        fileName: 'report.pdf',
        size: 2 * 1024 * 1024,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('2.0 MB'), findsOneWidget);
  });

  testWidgets('the attach button opens the Photo / Camera / File sheet',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(home: DmThreadScreen(threadId: 'a__me', dmService: dm)),
    );
    await tester.pump();
    ctrl.add(const []);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
  });

  testWidgets('tapping a conversation-starter fills the composer and it stays',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl, chips: ['What trail do you run?']);
    await tester.pumpWidget(
      MaterialApp(home: DmThreadScreen(threadId: 'a__me', dmService: dm, apiClient: _api())),
    );
    await tester.pump();
    ctrl.add(const []);
    await tester.pumpAndSettle();

    expect(find.text('Things to talk about'), findsOneWidget);
    await tester.tap(find.text('What trail do you run?'));
    await tester.pumpAndSettle();

    // Filled the composer for editing — and stays available as common ground.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'What trail do you run?',
    );
    expect(find.text('Things to talk about'), findsOneWidget);
  });

  testWidgets('block & report confirms then calls block and pops',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      DmThreadScreen(threadId: 'a__me', dmService: dm, apiClient: _api()),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    ctrl.add(const []);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block & report'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pumpAndSettle();

    expect(dm.blocked, ['a']);
    expect(find.byType(DmThreadScreen), findsNothing);
  });

  testWidgets('the header shows the other person, not "Conversation"',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    await tester.pumpWidget(
      MaterialApp(
        home: DmThreadScreen(
          threadId: 'a__me',
          dmService: dm,
          apiClient: _api({
            'a': {'name': 'Priya Nair', 'photo': '', 'online': true},
          }),
        ),
      ),
    );
    await tester.pump();
    ctrl.add(const []);
    await tester.pumpAndSettle();

    expect(find.text('Priya Nair'), findsOneWidget);
    expect(find.text('Conversation'), findsNothing);
  });

  testWidgets('tapping the header opens the other person\'s public profile',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ctrl = StreamController<List<DmMessage>>.broadcast();
    final dm = _FakeDm(ctrl);
    final pushed = <String>[];

    final router = GoRouter(
      initialLocation: '/dm/a__me',
      routes: [
        GoRoute(
          path: '/dm/:threadId',
          builder: (_, __) => DmThreadScreen(
            threadId: 'a__me',
            dmService: dm,
            apiClient: _api({
              'a': {'name': 'Priya Nair', 'photo': '', 'online': true},
            }),
          ),
        ),
        GoRoute(
          path: '/profile/user/:uid',
          builder: (_, s) {
            pushed.add(s.pathParameters['uid']!);
            return const Scaffold(body: Text('PROFILE PAGE'));
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    ctrl.add(const []);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Priya Nair'));
    await tester.pumpAndSettle();

    expect(pushed, ['a']);
    expect(find.text('PROFILE PAGE'), findsOneWidget);
  });
}
