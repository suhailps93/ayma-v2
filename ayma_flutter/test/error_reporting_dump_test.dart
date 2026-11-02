import 'package:ayma_flutter/services/error_reporting.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// J1: QA ran an unfiltered `adb logcat` across a warm self web-search
/// `/deep-dive` tap and the build-throw behind the "Something didn't load"
/// panel produced ZERO lines — the app's `FlutterError.onError` override had
/// replaced Flutter's default console dump, so a non-layout build-throw reached
/// only Crashlytics. These guard that the debug-build console dump now fires so
/// the next warm repro is capturable in logcat.
void main() {
  List<String> captureDebugPrint(void Function() body) {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      body();
    } finally {
      debugPrint = original;
    }
    return logs;
  }

  test('dumpBuildErrorToConsole dumps exception, library and stack to console',
      () {
    final details = FlutterErrorDetails(
      exception: StateError('deep-dive render boom'),
      stack: StackTrace.current,
      library: 'living report view',
    );
    final logs = captureDebugPrint(
      () => dumpBuildErrorToConsole(details, source: 'ErrorWidget.builder'),
    );
    final joined = logs.join('\n');
    expect(joined, contains('AYMA BUILD ERROR [ErrorWidget.builder]'));
    expect(joined, contains('deep-dive render boom'));
    expect(joined, contains('living report view'));
    // The full stack is dumped (both the manual line and dumpErrorToConsole).
    expect(joined, contains('stack:'));
  });

  test('dumpAsyncErrorToConsole dumps the error and stack to console', () {
    final logs = captureDebugPrint(
      () => dumpAsyncErrorToConsole(
        StateError('async boom'),
        StackTrace.current,
        source: 'PlatformDispatcher.onError',
      ),
    );
    final joined = logs.join('\n');
    expect(joined, contains('AYMA ASYNC ERROR [PlatformDispatcher.onError]'));
    expect(joined, contains('async boom'));
  });
}
