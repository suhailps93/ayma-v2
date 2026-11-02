import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/paged_fresh_data.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('ExplorePage.fromJson', () {
    test('parses a paged payload', () {
      final page = ExplorePage.fromJson({
        'cards': [
          {'uid': 'a', 'name': 'Ash'},
        ],
        'next_cursor': 'opaque',
        'has_more': true,
      });
      expect(page.cards, hasLength(1));
      expect(page.cards.single.uid, 'a');
      expect(page.nextCursor, 'opaque');
      expect(page.hasMore, isTrue);
    });

    test('tolerates the legacy {cards} shape during backend rollout', () {
      final page = ExplorePage.fromJson({
        'cards': [
          {'uid': 'a', 'name': 'Ash'},
        ],
      });
      expect(page.cards, hasLength(1));
      expect(page.nextCursor, isNull);
      expect(page.hasMore, isFalse);
    });

    test('treats a bare cursor as more pages', () {
      final page = ExplorePage.fromJson({
        'cards': [],
        'next_cursor': 'opaque',
      });
      expect(page.nextCursor, 'opaque');
      expect(page.hasMore, isTrue);
    });

    test('empty cursor means end of feed', () {
      final page = ExplorePage.fromJson({'cards': [], 'next_cursor': ''});
      expect(page.nextCursor, isNull);
      expect(page.hasMore, isFalse);
    });
  });

  group('ApiClient.explore', () {
    test('sends limit + cursor query params', () async {
      late Uri seen;
      final client = ApiClient(
        auth: MockFirebaseAuth(signedIn: true),
        httpClient: MockClient((req) async {
          seen = req.url;
          return http.Response(
              jsonEncode({'cards': [], 'has_more': false}), 200);
        }),
      );
      final page = await client.explore(q: 'hi', limit: 24, cursor: 'c1');
      expect(page.cards, isEmpty);
      expect(seen.queryParameters['limit'], '24');
      expect(seen.queryParameters['cursor'], 'c1');
      expect(seen.queryParameters['q'], 'hi');
    });

    test('omits an empty cursor', () async {
      late Uri seen;
      final client = ApiClient(
        auth: MockFirebaseAuth(signedIn: true),
        httpClient: MockClient((req) async {
          seen = req.url;
          return http.Response(jsonEncode({'cards': []}), 200);
        }),
      );
      await client.explore();
      expect(seen.queryParameters.containsKey('cursor'), isFalse);
      expect(seen.queryParameters['limit'], '24');
    });

    test('throws ApiException on non-200', () async {
      final client = ApiClient(
        auth: MockFirebaseAuth(signedIn: true),
        httpClient: MockClient((_) async => http.Response('boom', 500)),
      );
      expect(() => client.explore(), throwsA(isA<ApiException>()));
    });
  });

  group('PagedFreshData.state (design §5.2 matrix)', () {
    test('empty + error => refused', () {
      expect(
        const PagedFreshData<String>(error: 'x').state,
        FreshnessState.refused,
      );
    });

    test('items + error => stale (retained)', () {
      expect(
        const PagedFreshData<String>(items: ['a'], error: 'x').state,
        FreshnessState.stale,
      );
    });

    test('refreshing over items => syncing', () {
      expect(
        const PagedFreshData<String>(items: ['a'], refreshing: true).state,
        FreshnessState.syncing,
      );
    });

    test('cache paint => stale', () {
      expect(
        const PagedFreshData<String>(items: ['a'], isFromCache: true).state,
        FreshnessState.stale,
      );
    });

    test('paging keeps live (footer shows progress, not a strip)', () {
      expect(
        const PagedFreshData<String>(
          items: ['a'],
          loadingNextPage: true,
          hasMore: true,
        ).state,
        FreshnessState.live,
      );
    });

    test('next-page failure keeps live items', () {
      final feed = const PagedFreshData<String>(
        items: ['a'],
        nextPageError: 'net down',
        hasMore: true,
      );
      expect(feed.state, FreshnessState.live);
      expect(feed.nextPageError, isNotNull);
    });

    test('cold with nothing => syncing', () {
      expect(
        const PagedFreshData<String>().state,
        FreshnessState.syncing,
      );
    });

    test('copyWith replaces and clears', () {
      const feed = PagedFreshData<String>(
        items: ['a'],
        error: 'x',
        nextCursor: 'c',
      );
      final next = feed.copyWith(
        items: ['a', 'b'],
        clearError: true,
        clearNextCursor: true,
      );
      expect(next.items, ['a', 'b']);
      expect(next.error, isNull);
      expect(next.nextCursor, isNull);
      expect(feed.error, 'x'); // original untouched
    });
  });
}
