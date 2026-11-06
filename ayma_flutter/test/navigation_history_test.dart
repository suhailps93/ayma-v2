import 'package:ayma_flutter/services/navigation_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('navPageLabelForPath', () {
    test('names the registry destinations the way Ayma says them', () {
      expect(navPageLabelForPath('/'), 'the chat with Ayma');
      expect(navPageLabelForPath('/explore'), 'Explore');
      expect(navPageLabelForPath('/messages'), 'Messages');
      expect(navPageLabelForPath('/profile'), 'the You tab');
      expect(navPageLabelForPath('/matches'), 'New matches');
      expect(navPageLabelForPath('/settings/voice'), "Ayma's models");
      expect(navPageLabelForPath('/settings'), 'Settings');
    });

    test('names parameterized pages generically', () {
      expect(navPageLabelForPath('/profile/user/u-9'), 'their profile');
      expect(navPageLabelForPath('/dm/a__b'), 'a message thread');
      expect(navPageLabelForPath('/match/a__b'), 'a match report');
      expect(navPageLabelForPath('/deep-dive/abc'), 'a web-research report');
    });

    test('strips query strings and refuses pre-auth / public routes', () {
      expect(
        navPageLabelForPath('/profile/me/public?edit=photos'),
        'My public profile',
      );
      expect(navPageLabelForPath('/splash'), isNull);
      expect(navPageLabelForPath('/signin'), isNull);
      expect(navPageLabelForPath('/consent'), isNull);
      expect(navPageLabelForPath('/s/some-token'), isNull);
      expect(navPageLabelForPath(''), isNull);
    });
  });

  group('NavigationHistory', () {
    test('visit stacks pages; current/previous read off the top', () {
      final h = NavigationHistory();
      expect(h.current, isNull);
      expect(h.previous, isNull);
      expect(h.canGoBack, isFalse);
      h.visit('/matches');
      h.visit('/explore');
      expect(h.current?.path, '/explore');
      expect(h.current?.label, 'Explore');
      expect(h.previous?.path, '/matches');
      expect(h.previous?.label, 'New matches');
      expect(h.canGoBack, isTrue);
    });

    test('consecutive duplicates collapse; non-history routes are ignored', () {
      final h = NavigationHistory();
      h.visit('/explore');
      h.visit('/explore');
      h.visit('/signin');
      h.visit('/splash');
      expect(h.stack.map((e) => e.path), ['/explore']);
    });

    test('the stack is capped, dropping the oldest pages', () {
      final h = NavigationHistory(maxDepth: 3);
      h.visit('/');
      h.visit('/matches');
      h.visit('/explore');
      h.visit('/messages');
      expect(h.stack.map((e) => e.path), ['/matches', '/explore', '/messages']);
      expect(h.canGoBack, isTrue);
    });

    test(
      'takeBackTarget unwinds one step at a time, then stops at the root',
      () {
        final h = NavigationHistory();
        h.visit('/');
        h.visit('/matches');
        h.visit('/explore');
        expect(h.takeBackTarget()?.path, '/matches');
        expect(h.current?.path, '/matches');
        expect(h.takeBackTarget()?.path, '/');
        // At the root: no target, and the root entry is NOT consumed.
        expect(h.takeBackTarget(), isNull);
        expect(h.stack.map((e) => e.path), ['/']);
        expect(h.canGoBack, isFalse);
      },
    );

    test(
      'record of the previous page is a pop: it unwinds, never duplicates',
      () {
        final h = NavigationHistory();
        h.record('/matches'); // user opens Matches
        h.record('/explore'); // user pushes Explore
        h.record('/matches'); // user presses back — router reports Matches
        expect(h.stack.map((e) => e.path), ['/matches']);
        expect(h.canGoBack, isFalse);
        // A genuinely new forward navigation still stacks.
        h.record('/profile');
        expect(h.stack.map((e) => e.path), ['/matches', '/profile']);
      },
    );

    test('markCurrent truncates to a deeper entry (tab-history pop)', () {
      final h = NavigationHistory();
      h.visit('/');
      h.visit('/explore');
      h.visit('/messages');
      h.markCurrent('/');
      expect(h.stack.map((e) => e.path), ['/']);
    });

    test('clear forgets the session', () {
      final h = NavigationHistory();
      h.visit('/matches');
      h.visit('/explore');
      h.clear();
      expect(h.stack, isEmpty);
      expect(h.takeBackTarget(), isNull);
    });
  });
}
