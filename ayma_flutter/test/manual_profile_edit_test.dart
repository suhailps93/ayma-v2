import 'dart:convert';

import 'package:ayma_flutter/screens/manual_profile_edit_screen.dart';
import 'package:ayma_flutter/screens/profile_proposals_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

ApiClient _api(Future<http.Response> Function(http.Request) handler) =>
    ApiClient(
        httpClient: MockClient((r) => handler(r)),
        auth: MockFirebaseAuth(signedIn: true));

void main() {
  testWidgets('editor loads the public text and saves it with the version',
      (tester) async {
    Map<String, dynamic>? saved;
    final api = _api((r) async {
      if (r.method == 'GET') {
        return http.Response(
            jsonEncode({
              'text': '## Career\nShe is a nurse.',
              'version': 'v1',
              'max_chars': 12000,
            }),
            200,
            headers: _json);
      }
      saved = jsonDecode(r.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'ok': true}), 200, headers: _json);
    });
    bool? popped;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => popped = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                  builder: (_) => ManualProfileEditScreen(apiClient: api))),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('## Career\nShe is a nurse.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '## Career\nShe is a doctor.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saved, {'text': '## Career\nShe is a doctor.', 'base_version': 'v1'});
    expect(popped, isTrue);
  });

  testWidgets('a refused save shows the server reason and stays open',
      (tester) async {
    final api = _api((r) async {
      if (r.method == 'GET') {
        return http.Response(
            jsonEncode({'text': 'x', 'version': 'v1', 'max_chars': 12000}),
            200,
            headers: _json);
      }
      return http.Response(
          jsonEncode({
            'detail': {
              'code': 'contact_info',
              'message': "Phone numbers can't go on your public profile."
            }
          }),
          422,
          headers: _json);
    });
    await tester
        .pumpWidget(MaterialApp(home: ManualProfileEditScreen(apiClient: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text("Phone numbers can't go on your public profile."),
        findsOneWidget);
    expect(find.byType(ManualProfileEditScreen), findsOneWidget);
  });

  testWidgets('helper text explains own sections; custom section is sent as-is',
      (tester) async {
    Map<String, dynamic>? saved;
    final api = _api((r) async {
      if (r.method == 'GET') {
        return http.Response(
            jsonEncode({
              'text': '## Career\nShe is a nurse.',
              'version': 'v1',
              'max_chars': 12000
            }),
            200,
            headers: _json);
      }
      saved = jsonDecode(r.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'ok': true}), 200, headers: _json);
    });
    await tester
        .pumpWidget(MaterialApp(home: ManualProfileEditScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Add your own with a new "## Title" line'),
        findsOneWidget);
    expect(find.textContaining('Keep the ##'), findsNothing);

    const text = '## Career\nShe is a nurse.\n\n## My Travel Rules\nPack light.';
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, {'text': text, 'base_version': 'v1'});
  });

  testWidgets('a refused section title shows the server reason',
      (tester) async {
    final api = _api((r) async {
      if (r.method == 'GET') {
        return http.Response(
            jsonEncode({'text': 'x', 'version': 'v1', 'max_chars': 12000}),
            200,
            headers: _json);
      }
      return http.Response(
          jsonEncode({
            'detail': {
              'code': 'bad_title',
              'message': '"Family" is one of Ayma\'s own section names. '
                  'Pick a different title.'
            }
          }),
          422,
          headers: _json);
    });
    await tester
        .pumpWidget(MaterialApp(home: ManualProfileEditScreen(apiClient: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Pick a different title.'), findsOneWidget);
    expect(find.byType(ManualProfileEditScreen), findsOneWidget);
  });

  testWidgets('proposals show a diff and Apply / Dismiss remove the card',
      (tester) async {
    final calls = <String>[];
    final api = _api((r) async {
      if (r.method == 'GET') {
        return http.Response(
            jsonEncode({
              'proposals': [
                {
                  'page_id': 'interests',
                  'title': 'Interests',
                  'diff': [
                    {'op': 'same', 'text': 'She climbs.'},
                    {'op': 'remove', 'text': 'She bakes.'},
                    {'op': 'add', 'text': 'She surfs.'},
                  ],
                },
                {
                  'page_id': 'career',
                  'title': 'Career',
                  'diff': [
                    {'op': 'add', 'text': 'She is a doctor.'}
                  ],
                },
              ]
            }),
            200,
            headers: _json);
      }
      calls.add(r.url.path);
      return http.Response(jsonEncode({'ok': true}), 200, headers: _json);
    });
    await tester
        .pumpWidget(MaterialApp(home: ProfileProposalsScreen(apiClient: api)));
    await tester.pumpAndSettle();

    expect(find.text('+ She surfs.'), findsOneWidget);
    expect(find.text('- She bakes.'), findsOneWidget);
    expect(find.text('She climbs.'), findsOneWidget);

    await tester.tap(find.text('Apply').first);
    await tester.pumpAndSettle();
    expect(calls, ['/profile/proposals/interests/apply']);
    expect(find.text('Interests'), findsNothing);

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(calls.last, '/profile/proposals/career/dismiss');
    expect(find.text('No suggested updates.'), findsOneWidget);
  });
}
