import 'package:ayma_flutter/services/tour_anchors.dart';
import 'package:ayma_flutter/services/tour_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The auto-show gate's pure decision (§11.2): first-run full walkthrough,
/// new-feature spotlight, or nothing.
const _all = <TourFeature>[
  TourFeature(featureId: 'a', headline: 'A', subtitle: ''),
  TourFeature(featureId: 'b', headline: 'B', subtitle: ''),
  TourFeature(
    featureId: 'c',
    headline: 'C',
    subtitle: '',
    icon: Icons.star_rounded,
    anchorId: TourAnchors.homeOrb,
  ),
];

void main() {
  test('nothing seen → full first-run walkthrough, not a spotlight', () {
    final d = decideTour(<String>{}, all: _all);
    expect(d.show, isTrue);
    expect(d.spotlight, isFalse);
    expect(d.features.map((f) => f.featureId), ['a', 'b', 'c']);
  });

  test('some seen, new ids present → spotlight of ONLY the unseen, in order',
      () {
    final d = decideTour({'a'}, all: _all);
    expect(d.show, isTrue);
    expect(d.spotlight, isTrue);
    expect(d.features.map((f) => f.featureId), ['b', 'c']);
  });

  test('every current id seen → show nothing', () {
    final d = decideTour({'a', 'b', 'c'}, all: _all);
    expect(d.show, isFalse);
    expect(d.features, isEmpty);
  });

  test('unknown/stale ids in the seen set are ignored', () {
    final d = decideTour({'a', 'b', 'c', 'gone'}, all: _all);
    expect(d.show, isFalse);
  });

  test('the live tour content is non-empty and has unique feature ids', () {
    final ids = tourFeatures.map((f) => f.featureId).toList();
    expect(ids, isNotEmpty);
    expect(ids.toSet().length, ids.length, reason: 'feature_ids must be unique');
    // Every step either anchors a real UI element or is a deliberate centered
    // callout (null anchor); an anchored step may name any tab.
    for (final f in tourFeatures) {
      if (f.tab != null) {
        expect(f.anchorId, isNotNull,
            reason: '${f.featureId}: a tab is only meaningful with an anchor');
      }
    }
  });
}
