import 'dart:async';

import 'package:ayma_flutter/services/write_ack.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('passes through an acked write', () async {
    var ran = false;
    await awaitServerAck(Future(() => ran = true));
    expect(ran, isTrue);
  });

  test('a write the server never acks fails instead of hanging', () async {
    expect(
      awaitServerAck(
        Completer<void>().future,
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<WriteAckException>()),
    );
  });

  test('the ack failure reads as a plain sentence, not a stack trace',
      () async {
    try {
      await awaitServerAck(
        Completer<void>().future,
        timeout: const Duration(milliseconds: 20),
      );
      fail('should have thrown');
    } on WriteAckException catch (e) {
      expect('$e', contains('server did not confirm'));
      expect('$e', isNot(contains('WriteAckException')));
    }
  });

  test('a refused write propagates the refusal, not a timeout', () async {
    final refusal = StateError('permission denied');
    expect(awaitServerAck(Future<void>.error(refusal)), throwsA(refusal));
  });
}
