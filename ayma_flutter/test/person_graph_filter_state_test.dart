// Regression for the founder's "Hide all → tap chips → EMPTY canvas" bug (build
// 2495, My person graph). The filter AND-gates two facets (kind AND level);
// "Hide all" hid every kind AND every level, so un-hiding one KIND chip left all
// levels hidden and nothing rendered. The toggle now releases the vestigial
// all-hidden facet. Settled behaviour: Hide all = empty; tap a chip = exactly
// that type; tap more = ADD; Show all = everything.
import 'package:ayma_flutter/screens/person_graph_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A graph with 3 kinds across 3 levels: person(L0), section(L1), bullet(L2).
  const kinds = ['person', 'section', 'bullet'];
  const depths = [0, 1, 2];
  final nodes = <(String, int)>[
    ('person', 0),
    ('section', 1),
    ('bullet', 2),
  ];

  Set<String> visibleKinds(Set<String> hk, Set<int> hl) => {
        for (final (kind, level) in nodes)
          if (graphFilterPasses(kind, level, hk, hl)) kind
      };

  group('Hide-all then select shows exactly the selected types', () {
    test('Show-all state: everything visible', () {
      expect(visibleKinds({}, {}), {'person', 'section', 'bullet'});
    });

    test('Hide all: clean empty state', () {
      final hk = {...kinds};
      final hl = {...depths};
      expect(visibleKinds(hk, hl), isEmpty);
    });

    test('Hide all → tap a kind chip: EXACTLY that type (bug was empty)', () {
      var hk = {...kinds};
      var hl = {...depths};
      // Tap "You" (person kind). Pre-fix: levels stayed hidden → empty.
      (hk, hl) = toggleKindFilter('person', hk, hl, depths);
      expect(visibleKinds(hk, hl), {'person'},
          reason: 'un-hiding one kind after Hide all shows exactly that type');

      // Tap "Sections": ADDS section, keeps person.
      (hk, hl) = toggleKindFilter('section', hk, hl, depths);
      expect(visibleKinds(hk, hl), {'person', 'section'});

      // Tap "You" again: removes JUST person.
      (hk, hl) = toggleKindFilter('person', hk, hl, depths);
      expect(visibleKinds(hk, hl), {'section'});
    });

    test('Hide all → tap a level chip: symmetric release shows that level', () {
      var hk = {...kinds};
      var hl = {...depths};
      // Tap the L2 (bullet) level chip. Symmetric release clears hidden kinds.
      (hk, hl) = toggleLevelFilter(2, hk, hl, kinds);
      expect(visibleKinds(hk, hl), {'bullet'},
          reason: 'un-hiding one level after Hide all shows that level');
    });

    test('independent chips still work without the master controls', () {
      // From Show-all, hiding just "bullet" leaves the rest; re-adding restores.
      var hk = <String>{};
      var hl = <int>{};
      (hk, hl) = toggleKindFilter('bullet', hk, hl, depths);
      expect(visibleKinds(hk, hl), {'person', 'section'});
      (hk, hl) = toggleKindFilter('bullet', hk, hl, depths);
      expect(visibleKinds(hk, hl), {'person', 'section', 'bullet'});
    });
  });
}
