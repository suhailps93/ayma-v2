import 'dart:convert';

import 'package:ayma_flutter/screens/recovery_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('recover button calls /account/recover then routes home',
      (tester) async {
    final paths = <String>[];
    final api = ApiClient(
      auth: MockFirebaseAuth(signedIn: true),
      httpClient: MockClient((req) async {
        paths.add(req.url.path);
        return http.Response(jsonEncode({'ok': true}), 200);
      }),
    );

    final router = GoRouter(
      initialLocation: '/recover',
      routes: [
        GoRoute(
          path: '/recover',
          builder: (_, __) => RecoveryScreen(apiClient: api),
        ),
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('home')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('Welcome back'), findsOneWidget);
    await tester.tap(find.text('Recover my account'));
    await tester.pumpAndSettle();

    expect(paths, ['/account/recover']);
    expect(find.text('home'), findsOneWidget);
  });
}
