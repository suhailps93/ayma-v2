import 'package:ayma_flutter/widgets/selectable_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

int _end(String s, String sub) => s.indexOf(sub) + sub.length;

void main() {
  test('setPrivacy wraps a clean range', () {
    const body = 'I lead the analytics team in Lisbon.';
    final a = body.indexOf('the analytics team');
    final b = _end(body, 'the analytics team');
    expect(setPrivacy(body, a, b, true),
        'I lead {{private}}the analytics team{{/private}} in Lisbon.');
  });

  test('setPrivacy unwraps an existing span and re-balances', () {
    const body = 'a {{private}}b c{{/private}} d';
    final a = body.indexOf('b c');
    final b = _end(body, 'b c');
    expect(setPrivacy(body, a, b, false), 'a b c d');
  });

  test('setPrivacy keeps markers balanced when extending a private run', () {
    const body = 'one {{private}}two{{/private}} three';
    final a = body.indexOf('three');
    final r = setPrivacy(body, a, a + 5, true);
    expect('{{private}}'.allMatches(r).length,
        '{{/private}}'.allMatches(r).length);
    // both words end up inside a private span
    expect(RegExp(r'\{\{private\}\}two').hasMatch(r), isTrue);
    expect(RegExp(r'three\{\{/private\}\}').hasMatch(r), isTrue);
  });

  test('setPrivacy with an empty range only normalises stray markers', () {
    const messy = 'x {{private}}{{/private}}y {{private}}z';
    expect(setPrivacy(messy, 0, 0, false), 'x y {{private}}z{{/private}}');
  });
}
