import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/navigation_history.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feedback item 15 (founder, Nov 6, 2026): Ayma remembers the previous
/// page and "go back" / "take me back" returns there — one step per ask,
/// modals first, tours never fought, and a graceful line at the root.
void main() {
  late NavigationHistory history;
  late List<String> nav;
  late String current;

  AppCommandService svc({
    bool Function()? popupOpen,
    Future<bool> Function()? dismissPopup,
    bool Function()? tourActive,
    MockFirebaseAuth? auth,
    FakeFirebaseFirestore? firestore,
  }) {
    return AppCommandService(
      navigate: (p) {
        nav.add(p);
        current = p;
      },
      currentPath: () => current,
      navigationHistory: history,
      popupOpen: popupOpen ?? (() => false),
      dismissPopup: dismissPopup ?? (() async => false),
      tourActive: tourActive ?? (() => false),
      auth: auth,
      firestore: firestore,
    );
  }

  setUp(() {
    history = NavigationHistory();
    nav = <String>[];
    current = '';
    NavigationHistory.instance.clear();
  });

  tearDown(() {
    NavigationHistory.instance.clear();
  });

  test('A to B by Ayma command, then go back lands on A', () async {
    final s = svc();
    expect(s.handleCommand({'action': 'navigate', 'path': '/matches'}), isTrue);
    expect(s.handleCommand({'action': 'navigate', 'path': '/explore'}), isTrue);
    expect(history.current?.path, '/explore');
    expect(history.previous?.label, 'New matches');

    final out = await s.runGoBack();
    expect(out.ok, isTrue);
    expect(out.kind, GoBackKind.navigated);
    expect(out.message, 'Went back to New matches.');
    expect(nav.last, '/matches');
    expect(current, '/matches');
    expect(history.current?.path, '/matches');
  });

  test('double-back unwinds two steps, third is the graceful root', () async {
    final s = svc();
    s.handleCommand({'action': 'navigate', 'path': '/'});
    s.handleCommand({'action': 'navigate', 'path': '/matches'});
    s.handleCommand({'action': 'navigate', 'path': '/explore'});

    expect((await s.runGoBack()).kind, GoBackKind.navigated);
    expect(current, '/matches');
    expect((await s.runGoBack()).kind, GoBackKind.navigated);
    expect(current, '/');

    final third = await s.runGoBack();
    expect(third.ok, isFalse);
    expect(third.kind, GoBackKind.atRoot);
    expect(third.message, contains('nowhere to go back to'));
    expect(current, '/'); // still home — nothing exited, nothing failed open
    expect(nav, ['/', '/matches', '/explore', '/matches', '/']);
  });

  test(
    'back at the root is graceful: no navigation, history untouched',
    () async {
      final s = svc();
      history.visit('/explore');
      final out = await s.runGoBack();
      expect(out.ok, isFalse);
      expect(out.kind, GoBackKind.atRoot);
      expect(out.message, contains('Explore'));
      expect(nav, isEmpty);
      expect(history.stack.map((e) => e.path), ['/explore']);
    },
  );

  test('back with no history at all is graceful too', () async {
    final out = await svc().runGoBack();
    expect(out.ok, isFalse);
    expect(out.kind, GoBackKind.atRoot);
    expect(nav, isEmpty);
  });

  test('user-driven navigation is remembered as well as Ayma-driven', () async {
    history.record('/matches'); // the user tapped there themselves
    history.record('/explore');
    final out = await svc().runGoBack();
    expect(out.kind, GoBackKind.navigated);
    expect(nav, ['/matches']);
  });

  test(
    'open_profile and open_dm_thread (Ayma-driven) record history',
    () async {
      final auth = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'me'),
      );
      final s = svc(auth: auth);
      history.visit('/');
      expect(s.handleCommand({'action': 'open_profile', 'uid': 'u-9'}), isTrue);
      expect(history.current?.path, '/profile/user/u-9');
      expect(history.previous?.path, '/');
      expect(
        s.handleCommand({'action': 'open_dm_thread', 'uid': 'u-9'}),
        isTrue,
      );
      expect(history.current?.path, '/dm/me__u-9');

      final out = await s.runGoBack();
      expect(out.kind, GoBackKind.navigated);
      expect(nav.last, '/profile/user/u-9');
    },
  );

  test(
    'a modal up: first go-back dismisses it, second leaves the page',
    () async {
      var popup = true;
      var dismissals = 0;
      final s = svc(
        popupOpen: () => popup,
        dismissPopup: () async {
          dismissals++;
          popup = false;
          return true;
        },
      );
      history.visit('/matches');
      history.visit('/explore');

      final first = await s.runGoBack();
      expect(first.kind, GoBackKind.dismissedModal);
      expect(first.ok, isTrue);
      expect(first.message, contains('still on Explore'));
      expect(dismissals, 1);
      expect(nav, isEmpty); // stayed on the page
      expect(history.current?.path, '/explore'); // history untouched

      final second = await s.runGoBack();
      expect(second.kind, GoBackKind.navigated);
      expect(nav, ['/matches']);
    },
  );

  test('during a tour, go-back refuses and touches nothing', () async {
    var dismissals = 0;
    final s = svc(
      tourActive: () => true,
      popupOpen: () => true,
      dismissPopup: () async {
        dismissals++;
        return true;
      },
    );
    history.visit('/matches');
    history.visit('/explore');
    final out = await s.runGoBack();
    expect(out.ok, isFalse);
    expect(out.kind, GoBackKind.tourActive);
    expect(out.message, contains('tour'));
    expect(nav, isEmpty);
    expect(dismissals, 0); // did not fight the tour for the screen
    expect(history.current?.path, '/explore');
  });

  test('the sync dispatcher refuses go_back (it is async-owned)', () {
    expect(svc().handleCommand({'action': 'go_back'}), isFalse);
  });

  test('ScreenContext carries the previous page for Ayma', () {
    NavigationHistory.instance.visit('/matches');
    NavigationHistory.instance.visit('/explore');
    final json = const ScreenContext(screen: 'explore').toJson();
    expect(json['previous_route'], '/matches');
    expect(json['previous_label'], 'New matches');
  });

  group('command doc listener (go_back ack)', () {
    late FakeFirebaseFirestore fs;
    late MockFirebaseAuth auth;

    setUp(() {
      fs = FakeFirebaseFirestore();
      auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me'));
    });

    test(
      'executes, acks ok with kind + landed page, deletes pending',
      () async {
        history.visit('/matches');
        history.visit('/explore');
        final s = svc(auth: auth, firestore: fs)..start();
        addTearDown(s.stop);
        await fs.doc('users/me/app_commands/pending').set({
          'action': 'go_back',
          'id': 'gb-1',
          'ts': Timestamp.now(),
        });
        await pumpEventQueue();

        expect(nav, ['/matches']);
        final ack = (await fs.doc('users/me/app_commands/ack').get()).data();
        expect(ack?['id'], 'gb-1');
        expect(ack?['ok'], isTrue);
        expect(ack?['kind'], 'navigated');
        expect(ack?['result'], 'Went back to New matches.');
        expect(ack?['current'], 'New matches');
        expect(
          (await fs.doc('users/me/app_commands/pending').get()).exists,
          isFalse,
        );
      },
    );

    test('at the root the ack is ok=false with the sayable reason', () async {
      history.visit('/explore');
      final s = svc(auth: auth, firestore: fs)..start();
      addTearDown(s.stop);
      await fs.doc('users/me/app_commands/pending').set({
        'action': 'go_back',
        'id': 'gb-2',
        'ts': Timestamp.now(),
      });
      await pumpEventQueue();

      expect(nav, isEmpty);
      final ack = (await fs.doc('users/me/app_commands/ack').get()).data();
      expect(ack?['ok'], isFalse);
      expect(ack?['kind'], 'atRoot');
      expect(ack?['reason'], contains('nowhere to go back to'));
      expect(ack?['current'], 'Explore');
    });
  });
}
