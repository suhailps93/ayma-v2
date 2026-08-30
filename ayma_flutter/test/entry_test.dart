import 'package:ayma_flutter/routing/entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session_mode maps to the entry route', () {
    expect(entryRouteFor('marketing'), '/chat');
    expect(entryRouteFor('interview'), '/preboarding');
    expect(entryRouteFor('active'), '/');
    // unknown -> safest (marketing) landing
    expect(entryRouteFor('something-else'), '/chat');
  });
}
