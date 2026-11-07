// Ayma-driven photo-carousel navigation (founder clarification,
// 2026-11-06): opening a profile already worked — the missing piece was
// moving WITHIN its photo carousel. "Click the third picture" queues a
// `carousel_photo` command (backend `show_profile_photo`, both voice and
// text lanes); AppCommandService runs it against the handle the mounted
// ProfilePhotoHeader registered in PhotoCarouselRegistry, and acks with
// the real photo count so an out-of-range ask ("photo 5" of 3) is
// answered honestly instead of moving wildly.
import 'package:ayma_flutter/screens/public_profile_screen.dart'
    show ProfilePhotoHeader;
import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:ayma_flutter/services/photo_carousel_registry.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake carousel handle whose animate settles instantly, like the real
/// PageView reporting its new page through onPageChanged.
class _FakeCarousel {
  _FakeCarousel({required this.count, this.page = 0});

  final int count;
  int page;
  final List<int> animateCalls = [];

  PhotoCarouselHandle get handle => PhotoCarouselHandle(
    photoCount: () => count,
    currentPage: () => page,
    animateToPage: (target) {
      animateCalls.add(target);
      page = target;
    },
  );
}

PhotoCarouselRegistry _registryWith(_FakeCarousel fake) {
  final registry = PhotoCarouselRegistry();
  registry.register(fake.handle);
  return registry;
}

void main() {
  group('PhotoCarouselRegistry', () {
    test('goto jumps to the requested 1-based photo', () {
      final fake = _FakeCarousel(count: 3);
      final registry = _registryWith(fake);
      final out = registry.perform(op: 'goto', index: 3);
      expect(out.ok, isTrue);
      expect(out.photoCount, 3);
      expect(out.currentPhoto, 3);
      expect(fake.animateCalls, [2]); // 0-based page 2
      expect(fake.page, 2);
    });

    test('next and previous step one photo at a time', () {
      final fake = _FakeCarousel(count: 3);
      final registry = _registryWith(fake);
      var out = registry.perform(op: 'next');
      expect(out.ok, isTrue);
      expect(out.currentPhoto, 2);
      out = registry.perform(op: 'next');
      expect(out.ok, isTrue);
      expect(out.currentPhoto, 3);
      out = registry.perform(op: 'previous');
      expect(out.ok, isTrue);
      expect(out.currentPhoto, 2);
      expect(fake.animateCalls, [1, 2, 1]);
    });

    test('next at the last photo and previous at the first do not move', () {
      final fake = _FakeCarousel(count: 3, page: 2);
      final registry = _registryWith(fake);
      var out = registry.perform(op: 'next');
      expect(out.ok, isFalse);
      expect(out.reason, 'at_last');
      expect(out.photoCount, 3);
      expect(out.currentPhoto, 3);
      fake.page = 0;
      out = registry.perform(op: 'previous');
      expect(out.ok, isFalse);
      expect(out.reason, 'at_first');
      expect(out.photoCount, 3);
      expect(fake.animateCalls, isEmpty);
    });

    test('out-of-range goto returns the real count without moving', () {
      final fake = _FakeCarousel(count: 3, page: 1);
      final registry = _registryWith(fake);
      final out = registry.perform(op: 'goto', index: 5);
      expect(out.ok, isFalse);
      expect(out.reason, 'out_of_range');
      expect(out.photoCount, 3);
      expect(out.requestedPhoto, 5);
      expect(out.currentPhoto, 2); // still on photo 2
      expect(out.resultText, 'There are only 3 photos on this profile.');
      expect(fake.animateCalls, isEmpty);
      expect(fake.page, 1);
    });

    test('goto photo 0 is out of range too', () {
      final fake = _FakeCarousel(count: 3);
      final registry = _registryWith(fake);
      final out = registry.perform(op: 'goto', index: 0);
      expect(out.ok, isFalse);
      expect(out.reason, 'out_of_range');
      expect(out.photoCount, 3);
      expect(fake.animateCalls, isEmpty);
    });

    test('last jumps to the final photo', () {
      final fake = _FakeCarousel(count: 4);
      final registry = _registryWith(fake);
      final out = registry.perform(op: 'last');
      expect(out.ok, isTrue);
      expect(out.currentPhoto, 4);
      expect(fake.animateCalls, [3]);
    });

    test('no registered carousel is an honest no_carousel', () {
      final registry = PhotoCarouselRegistry();
      final out = registry.perform(op: 'goto', index: 1);
      expect(out.ok, isFalse);
      expect(out.reason, 'no_carousel');
      expect(out.photoCount, 0);
    });
  });

  group('AppCommandService carousel_photo', () {
    test('runCarouselPhoto jumps, steps, and bounds-checks', () {
      final fake = _FakeCarousel(count: 3);
      final svc = AppCommandService(photoCarousel: _registryWith(fake));

      var out = svc.runCarouselPhoto({
        'action': 'carousel_photo',
        'op': 'goto',
        'index': 3,
      });
      expect(out.ok, isTrue);
      expect(out.currentPhoto, 3);
      expect(fake.page, 2);

      out = svc.runCarouselPhoto({'action': 'carousel_photo', 'op': 'next'});
      expect(out.ok, isFalse); // already on the last photo
      expect(out.reason, 'at_last');

      out = svc.runCarouselPhoto({
        'action': 'carousel_photo',
        'op': 'previous',
      });
      expect(out.ok, isTrue);
      expect(out.currentPhoto, 2);

      // The founder case: photo 5 of 3 — no move, real count back.
      out = svc.runCarouselPhoto({
        'action': 'carousel_photo',
        'op': 'goto',
        'index': 5,
      });
      expect(out.ok, isFalse);
      expect(out.reason, 'out_of_range');
      expect(out.photoCount, 3);
      expect(fake.page, 1);
    });

    test('handleCommand reports the same outcome as a bool', () {
      final fake = _FakeCarousel(count: 2);
      final svc = AppCommandService(photoCarousel: _registryWith(fake));
      expect(
        svc.handleCommand({
          'action': 'carousel_photo',
          'op': 'goto',
          'index': 2,
        }),
        isTrue,
      );
      expect(
        svc.handleCommand({
          'action': 'carousel_photo',
          'op': 'goto',
          'index': 4,
        }),
        isFalse,
      );
      expect(fake.page, 1);
    });

    test('the Firestore command acks with the photo count', () async {
      final fs = FakeFirebaseFirestore();
      final auth = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'me'),
      );
      final fake = _FakeCarousel(count: 3);
      final svc = AppCommandService(
        firestore: fs,
        auth: auth,
        navigate: (_) {},
        photoCarousel: _registryWith(fake),
      )..start();
      addTearDown(svc.stop);

      DocumentReference<Map<String, dynamic>> pending() =>
          fs.doc('users/me/app_commands/pending');
      DocumentReference<Map<String, dynamic>> ack() =>
          fs.doc('users/me/app_commands/ack');

      await pending().set({
        'action': 'carousel_photo',
        'op': 'goto',
        'index': 5,
        'id': 'cmd-photo-5',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      final ackDoc = (await ack().get()).data();
      expect(ackDoc?['id'], 'cmd-photo-5');
      expect(ackDoc?['ok'], isFalse);
      expect(ackDoc?['reason'], 'out_of_range');
      expect(ackDoc?['photo_count'], 3);
      expect(ackDoc?['requested_photo'], 5);
      expect(ackDoc?['result'], 'There are only 3 photos on this profile.');
      expect((await pending().get()).exists, isFalse);
      expect(fake.animateCalls, isEmpty); // never moved

      await pending().set({
        'action': 'carousel_photo',
        'op': 'goto',
        'index': 2,
        'id': 'cmd-photo-2',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      final ack2 = (await ack().get()).data();
      expect(ack2?['id'], 'cmd-photo-2');
      expect(ack2?['ok'], isTrue);
      expect(ack2?['photo_count'], 3);
      expect(ack2?['current_photo'], 2);
      expect(fake.animateCalls, [1]);
    });
  });

  group('ProfilePhotoHeader registration', () {
    testWidgets('the mounted header is the carousel commands drive', (
      tester,
    ) async {
      PhotoCarouselRegistry.instance.clear();
      addTearDown(PhotoCarouselRegistry.instance.clear);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProfilePhotoHeader(
                photos: [
                  'https://example.com/p1.jpg',
                  'https://example.com/p2.jpg',
                  'https://example.com/p3.jpg',
                ],
                seed: 'her',
                name: 'Dana',
                age: 30,
                location: 'Berlin',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final registry = PhotoCarouselRegistry.instance;
      expect(registry.hasCarousel, isTrue);
      expect(registry.active!.photoCount(), 3);
      expect(registry.active!.currentPage(), 0);

      // "Show the third picture" — the real PageView animates to page 2.
      final out = registry.perform(op: 'goto', index: 3);
      expect(out.ok, isTrue);
      await tester.pumpAndSettle();
      expect(registry.active!.currentPage(), 2);

      // Out of range through the real widget: no move, real count.
      final miss = registry.perform(op: 'goto', index: 5);
      expect(miss.ok, isFalse);
      expect(miss.photoCount, 3);
      await tester.pumpAndSettle();
      expect(registry.active!.currentPage(), 2);
    });
  });
}
