import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/copilot_highlight.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('copilotLocate posts the frame + goal and parses the target', () async {
    late http.Request seen;
    final mockHttp = MockClient((request) async {
      seen = request;
      return http.Response(
        jsonEncode({
          'found': true,
          'x': 0.82,
          'y': 0.91,
          'w': 0.14,
          'h': 0.06,
          'label': 'Send',
          'kind': 'button',
          'confidence': 0.9,
          'say': 'Tap Send.',
        }),
        200,
      );
    });
    final api = ApiClient(
      httpClient: mockHttp,
      auth: MockFirebaseAuth(signedIn: true),
    );
    final target = await api.copilotLocate(
      frameBytes: const [10, 20, 30],
      goal: 'send this message',
    );
    expect(seen.url.path, '/copilot/locate');
    final body = jsonDecode(seen.body) as Map<String, dynamic>;
    expect(body['goal'], 'send this message');
    expect(body['mime'], 'image/jpeg');
    expect(base64Decode(body['image_base64'] as String), [10, 20, 30]);
    expect(target.found, isTrue);
    expect(target.kind, CopilotTargetKind.button);
    expect(target.label, 'Send');
  });

  test('copilotLocate surfaces a 502 as an ApiException', () async {
    final mockHttp = MockClient((request) async {
      return http.Response(jsonEncode({'detail': 'down'}), 502);
    });
    final api = ApiClient(
      httpClient: mockHttp,
      auth: MockFirebaseAuth(signedIn: true),
    );
    await expectLater(
      api.copilotLocate(frameBytes: const [1], goal: 'pay'),
      throwsA(isA<ApiException>()),
    );
  });
}
