import 'dart:convert';

import 'package:ayma_flutter/screens/connectors_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/instagram_service.dart';
import 'package:ayma_flutter/services/meta_integrations.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

/// Google backend mock. `connected`/`email` are mutable so a connect or
/// disconnect round trip flips what the next `/google/status` returns.
ApiClient _api({bool connected = false, String email = ''}) {
  var isConnected = connected;
  var who = email;
  final mock = MockClient((req) async {
    final p = req.url.path;
    if (p == '/google/status') {
      return http.Response(
        jsonEncode({'connected': isConnected, 'email': who}),
        200,
        headers: _json,
      );
    }
    if (p == '/google/auth-url') {
      return http.Response(
        jsonEncode({'url': 'https://accounts.google.com/o/oauth2/auth?x=1'}),
        200,
        headers: _json,
      );
    }
    if (p == '/google/connect') {
      isConnected = true;
      who = 'you@gmail.com';
      return http.Response(jsonEncode({'email': who}), 200, headers: _json);
    }
    if (p == '/google/disconnect') {
      isConnected = false;
      who = '';
      return http.Response(jsonEncode({'ok': true}), 200, headers: _json);
    }
    return http.Response('{}', 200, headers: _json);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

/// Instagram service stub — never touches Firestore in the test.
class _FakeInstagram extends InstagramService {
  _FakeInstagram({this.connected = false});
  final bool connected;
  @override
  Future<bool> status() async => connected;
}

Widget _host(ConnectorsScreen screen) {
  final router = GoRouter(
    initialLocation: ConnectorsScreen.path,
    routes: [
      GoRoute(path: ConnectorsScreen.path, builder: (_, __) => screen),
      GoRoute(
        path: '/settings/instagram',
        builder: (_, __) => const Scaffold(body: Text('ROUTE instagram')),
      ),
    ],
  );
  return MaterialApp.router(theme: AymaTheme.light, routerConfig: router);
}

void main() {
  tearDown(() => MetaIntegrations.enabled.value = false);

  testWidgets('Google: not connected shows Connect; the flow opens the OAuth '
      'URL and connects', (tester) async {
    MetaIntegrations.enabled.value = false;
    final opened = <Uri>[];
    await tester.pumpWidget(_host(
      ConnectorsScreen(
        apiClient: _api(connected: false),
        instagramService: _FakeInstagram(),
        launcher: (u) async {
          opened.add(u);
          return true;
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Not connected'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);

    // Connect → consent dialog → Continue → OAuth URL opens → code dialog.
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Connect Google'), findsOneWidget);
    await tester.tap(find.text('Continue to Google'));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.host, 'accounts.google.com');

    // The shared "Finish connecting" code dialog is now open: paste + Connect.
    expect(find.text('Finish connecting'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'code=abc123');
    await tester.tap(find.widgetWithText(TextButton, 'Connect'));
    await tester.pumpAndSettle();

    // Status reloaded → connected to the returned email, Disconnect offered.
    expect(find.textContaining('Connected · you@gmail.com'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Disconnect'), findsOneWidget);
  });

  testWidgets('Google: connected shows the email + Disconnect; disconnecting '
      'clears it', (tester) async {
    await tester.pumpWidget(_host(
      ConnectorsScreen(
        apiClient: _api(connected: true, email: 'me@gmail.com'),
        instagramService: _FakeInstagram(),
        launcher: (_) async => true,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Connected · me@gmail.com'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(find.text('Not connected'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
  });

  testWidgets('Instagram is shown as unavailable when the meta flag is off '
      '(never a dead button)', (tester) async {
    MetaIntegrations.enabled.value = false;
    await tester.pumpWidget(_host(
      ConnectorsScreen(
        apiClient: _api(),
        instagramService: _FakeInstagram(),
        launcher: (_) async => true,
      ),
    ));
    await tester.pumpAndSettle();

    final igTile = find.byKey(const Key('connector_instagram'));
    expect(igTile, findsOneWidget);
    expect(
      find.descendant(of: igTile, matching: find.text('Not available in this version')),
      findsOneWidget,
    );
    // No connect/manage button inside the Instagram tile.
    expect(find.descendant(of: igTile, matching: find.byType(FilledButton)),
        findsNothing);
    expect(find.descendant(of: igTile, matching: find.byType(OutlinedButton)),
        findsNothing);
  });

  testWidgets('Instagram offers Connect when the meta flag is on, and opens '
      'the Instagram screen', (tester) async {
    MetaIntegrations.enabled.value = true;
    await tester.pumpWidget(_host(
      ConnectorsScreen(
        apiClient: _api(),
        instagramService: _FakeInstagram(connected: false),
        launcher: (_) async => true,
      ),
    ));
    await tester.pumpAndSettle();

    final igTile = find.byKey(const Key('connector_instagram'));
    final igConnect =
        find.descendant(of: igTile, matching: find.widgetWithText(FilledButton, 'Connect'));
    expect(igConnect, findsOneWidget);
    await tester.tap(igConnect);
    await tester.pumpAndSettle();
    expect(find.text('ROUTE instagram'), findsOneWidget);
  });
}
