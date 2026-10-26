import 'package:ayma_flutter/services/error_reporting.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('layout overflows are logged loudly in debug; other errors are not',
      () {
    final logged = <String>[];
    final original = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logged.add(m ?? '');
    addTearDown(() => debugPrint = original);

    logLayoutErrorLoudly(FlutterErrorDetails(
      exception: FlutterError(
        'A RenderFlex overflowed by 42 pixels on the bottom.',
      ),
    ));
    logLayoutErrorLoudly(FlutterErrorDetails(exception: StateError('nope')));

    expect(logged, hasLength(1));
    expect(logged.single, contains('AYMA LAYOUT ERROR'));
    expect(logged.single, contains('overflowed by 42 pixels'));
  });
}
