import 'dart:convert';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:ayma_flutter/services/api_client.dart';

void main() {
  test('chat() sends the message with a Bearer token and returns reply',
      () async {
    final auth = MockFirebaseAuth(signedIn: true);
    late http.Request captured;

    final mockHttp = MockClient((request) async {
      captured = request;
      return http.Response(jsonEncode({'reply': 'hi back'}), 200);
    });

    final client = ApiClient(httpClient: mockHttp, auth: auth);
    final reply = await client.chat('hello');

    expect(reply, 'hi back');
    expect(captured.url.path, '/chat');
    expect(captured.headers['Authorization'], startsWith('Bearer '));
    expect(jsonDecode(captured.body), {'message': 'hello'});
  });

  test('chat() throws ApiException on non-200', () async {
    final auth = MockFirebaseAuth(signedIn: true);
    final mockHttp = MockClient((_) async => http.Response('nope', 500));
    final client = ApiClient(httpClient: mockHttp, auth: auth);

    expect(() => client.chat('x'), throwsA(isA<ApiException>()));
  });
}
