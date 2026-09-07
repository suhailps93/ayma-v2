import 'package:ayma_flutter/util/text_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('diffLines', () {
    test('identical text is all equal', () {
      final d = diffLines('a\nb\nc', 'a\nb\nc');
      expect(d.map((l) => l.kind), everyElement(DiffKind.equal));
      expect(d.map((l) => l.text), ['a', 'b', 'c']);
    });

    test('a pure insertion in the middle', () {
      final d = diffLines('a\nc', 'a\nb\nc');
      expect(d, [
        const DiffLine(DiffKind.equal, 'a', oldIndex: 0, newIndex: 0),
        const DiffLine(DiffKind.insert, 'b', newIndex: 1),
        const DiffLine(DiffKind.equal, 'c', oldIndex: 1, newIndex: 2),
      ]);
    });

    test('a pure deletion', () {
      final d = diffLines('a\nb\nc', 'a\nc');
      expect(d.where((l) => l.kind == DiffKind.delete).map((l) => l.text),
          ['b']);
      expect(d.where((l) => l.kind == DiffKind.equal).map((l) => l.text),
          ['a', 'c']);
    });

    test('a replaced line: delete then insert', () {
      final d = diffLines('one\ntwo\nthree', 'one\nTWO\nthree');
      expect(d.map((l) => '${l.kind.name}:${l.text}'), [
        'equal:one',
        'delete:two',
        'insert:TWO',
        'equal:three',
      ]);
    });

    test('empty old text -> everything inserted', () {
      final d = diffLines('', 'x\ny');
      expect(d.map((l) => l.kind), [DiffKind.insert, DiffKind.insert]);
    });

    test('empty new text -> everything deleted', () {
      final d = diffLines('x\ny', '');
      expect(d.map((l) => l.kind), [DiffKind.delete, DiffKind.delete]);
    });

    test('CRLF is normalised', () {
      final d = diffLines('a\r\nb', 'a\nb');
      expect(d.map((l) => l.kind), everyElement(DiffKind.equal));
    });

    test('indices point back into each side', () {
      final d = diffLines('keep\ndrop\nkeep2', 'keep\nkeep2\nadd');
      final keep2 = d.firstWhere((l) => l.text == 'keep2');
      expect(keep2.kind, DiffKind.equal);
      expect(keep2.oldIndex, 2);
      expect(keep2.newIndex, 1);
    });
  });

  group('textsEqual', () {
    test('true across CRLF differences', () {
      expect(textsEqual('a\r\nb\r\n', 'a\nb\n'), isTrue);
    });
    test('false when content differs', () {
      expect(textsEqual('a', 'b'), isFalse);
    });
  });

  group('diffWords', () {
    test('shared prefix and suffix, one word changed', () {
      final spans = diffWords('the quick brown fox', 'the quick red fox');
      expect(spans.where((s) => s.kind == DiffKind.delete).map((s) => s.text),
          ['brown']);
      expect(spans.where((s) => s.kind == DiffKind.insert).map((s) => s.text),
          ['red']);
      // the unchanged words survive as equal spans
      final equalText =
          spans.where((s) => s.kind == DiffKind.equal).map((s) => s.text).join();
      expect(equalText.contains('the quick '), isTrue);
      expect(equalText.contains(' fox'), isTrue);
    });

    test('appended words are insert-only', () {
      final spans = diffWords('hello world', 'hello world again');
      expect(spans.any((s) => s.kind == DiffKind.delete), isFalse);
      expect(spans.where((s) => s.kind == DiffKind.insert).map((s) => s.text),
          [' again']);
    });

    test('identical lines produce only equal spans', () {
      final spans = diffWords('same line here', 'same line here');
      expect(spans.map((s) => s.kind), everyElement(DiffKind.equal));
    });
  });
}
