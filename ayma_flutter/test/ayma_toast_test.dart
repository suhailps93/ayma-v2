import 'package:ayma_flutter/services/screen_capture.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:ayma_flutter/widgets/ayma_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _nav = ValueKey('nav');
const _behind = ValueKey('behind');
final _toast = find.byKey(const ValueKey('ayma_toast'));

/// An app shaped like Ayma's: the toast host above the router, and a page
/// with a bottom nav bar of the real bar's height.
Future<void> _pump(
  WidgetTester tester, {
  ThemeData? theme,
  bool host = true,
  MediaQueryData? media,
  VoidCallback? onBehind,
}) async {
  Widget page = Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: TextButton(
        key: _behind,
        onPressed: onBehind ?? () {},
        child: const Text('Behind'),
      ),
    ),
    bottomNavigationBar: const SizedBox(
      key: _nav,
      height: AymaTabBar.contentHeight,
    ),
  );
  if (media != null) page = MediaQuery(data: media, child: page);
  await tester.pumpWidget(MaterialApp(
    theme: theme ?? AymaTheme.light,
    builder: host
        ? (context, child) {
            final c = child!;
            return media == null
                ? AymaToastHost(child: c)
                : MediaQuery(data: media, child: AymaToastHost(child: c));
          }
        : null,
    home: page,
  ));
}

BuildContext _ctx(WidgetTester tester) => tester.element(find.byKey(_behind));

void main() {
  testWidgets('shows a success toast with its icon and label, then '
      'auto-dismisses after 3 s', (tester) async {
    await _pump(tester);
    AymaToast.show(_ctx(tester), 'Liked.', kind: AymaToastKind.success);
    await tester.pumpAndSettle();
    expect(_toast, findsOneWidget);
    expect(find.text('Liked.'), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2900));
    expect(_toast, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(_toast, findsNothing);
  });

  testWidgets('a new toast replaces the one on screen; never two at once',
      (tester) async {
    await _pump(tester);
    AymaToast.show(_ctx(tester), 'First');
    await tester.pumpAndSettle();
    AymaToast.show(_ctx(tester), 'Second', kind: AymaToastKind.error);
    await tester.pumpAndSettle();
    expect(_toast, findsOneWidget);
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('ERROR'), findsOneWidget);
    // The replacement restarts the clock: still up 4 s after the first.
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Second'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(_toast, findsNothing);
  });

  testWidgets('tap dismisses', (tester) async {
    await _pump(tester);
    AymaToast.show(_ctx(tester), 'Saved', kind: AymaToastKind.success);
    await tester.pumpAndSettle();
    await tester.tap(_toast);
    await tester.pumpAndSettle();
    expect(_toast, findsNothing);
  });

  testWidgets('swipe down dismisses; a short drag springs back',
      (tester) async {
    await _pump(tester);
    AymaToast.show(_ctx(tester), 'Saved');
    await tester.pumpAndSettle();
    await tester.timedDrag(
        _toast, const Offset(0, 20), const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(_toast, findsOneWidget);
    await tester.drag(_toast, const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(_toast, findsNothing);
  });

  testWidgets('action runs once, dismisses, and keeps the toast up 5 s',
      (tester) async {
    await _pump(tester);
    var taps = 0;
    AymaToast.show(
      _ctx(tester),
      'Removed that photo',
      action: AymaToastAction(label: 'Undo', onPressed: () => taps++),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Undo'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(_toast, findsNothing);
  });

  test('durations: 3 s, 5 s with an action or for an error, 6 s for both', () {
    Duration d(AymaToastKind k, bool a) =>
        AymaToast.durationFor(k, hasAction: a);
    expect(d(AymaToastKind.success, false), const Duration(seconds: 3));
    expect(d(AymaToastKind.info, true), const Duration(seconds: 5));
    expect(d(AymaToastKind.error, false), const Duration(seconds: 5));
    expect(d(AymaToastKind.error, true), const Duration(seconds: 6));
  });

  testWidgets('hide() dismisses', (tester) async {
    await _pump(tester);
    AymaToast.show(_ctx(tester), 'Hello');
    await tester.pumpAndSettle();
    AymaToast.hide();
    await tester.pumpAndSettle();
    expect(_toast, findsNothing);
  });

  testWidgets('sits above the bottom nav bar, not over it', (tester) async {
    await _pump(tester);
    AymaToast.show(_ctx(tester), 'Profile saved');
    await tester.pumpAndSettle();
    final toast = tester.getRect(_toast);
    final nav = tester.getRect(find.byKey(_nav));
    expect(toast.bottom, lessThanOrEqualTo(nav.top));
    expect(toast.left, greaterThanOrEqualTo(16));
  });

  testWidgets('rises above the keyboard when it is taller than the nav bar',
      (tester) async {
    const keyboard = 320.0;
    await _pump(tester,
        media: const MediaQueryData(
          size: Size(800, 600),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ));
    AymaToast.show(_ctx(tester), 'Hi');
    await tester.pumpAndSettle();
    expect(tester.getRect(_toast).bottom, lessThanOrEqualTo(600 - keyboard));
  });

  testWidgets('taps outside the card reach the page beneath', (tester) async {
    var behind = 0;
    await _pump(tester, onBehind: () => behind++);
    AymaToast.show(_ctx(tester), 'Hello');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_behind));
    expect(behind, 1);
    expect(_toast, findsOneWidget);
  });

  testWidgets('long text is capped at two lines with an ellipsis',
      (tester) async {
    await _pump(tester);
    AymaToast.show(_ctx(tester), 'A very long message. ' * 30);
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.textContaining('A very long'));
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.getSize(_toast).height, lessThan(100));
  });

  testWidgets('reduced motion shows it at once, no slide', (tester) async {
    await _pump(tester,
        media: const MediaQueryData(
          size: Size(800, 600),
          disableAnimations: true,
        ));
    AymaToast.show(_ctx(tester), 'Hi');
    await tester.pump();
    final fade = tester.widget<FadeTransition>(find
        .ancestor(of: _toast, matching: find.byType(FadeTransition))
        .first);
    expect(fade.opacity.value, 1);
  });

  testWidgets('works without a host via the root overlay', (tester) async {
    await _pump(tester, host: false);
    AymaToast.show(_ctx(tester), 'Copied', kind: AymaToastKind.success);
    await tester.pump();
    expect(find.text('Copied'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(_toast, findsNothing);
  });

  testWidgets('announced as a live region; text reaches screen context but '
      'its action is user-only', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    AymaToast.show(
      _ctx(tester),
      "Couldn't reach Ayma.",
      kind: AymaToastKind.error,
      action: AymaToastAction(label: 'Retry', onPressed: () {}),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.descendant(
        of: _toast,
        matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.liveRegion == true),
      )),
      isSemantics(isLiveRegion: true),
    );
    final root = tester.binding.rootPipelineOwner.semanticsOwner
            ?.rootSemanticsNode ??
        tester.getSemantics(find.byType(MaterialApp));
    final snap = captureSemantics(root);
    expect(snap.text, contains("Couldn't reach Ayma."));
    final retry = snap.controls.firstWhere((c) => c.label == 'Retry');
    expect(retry.noAct, isTrue);
    handle.dispose();
  });

  for (final dark in [false, true]) {
    for (final accent in [
      AymaColors.accent,
      const HSLColor.fromAHSL(1, 55, 1, 0.6).toColor(), // pale yellow
      const HSLColor.fromAHSL(1, 230, 0.8, 0.25).toColor(), // deep navy
    ]) {
      testWidgets(
          '${dark ? 'dark' : 'light'} theme, accent $accent: icon >= 3:1 and '
          'action >= 4.5:1 on the card', (tester) async {
        final theme = dark
            ? AymaTheme.darkWithAccent(accent)
            : AymaTheme.lightWithAccent(accent);
        await _pump(tester, theme: theme);
        for (final kind in AymaToastKind.values) {
          AymaToast.show(
            _ctx(tester),
            'Message',
            kind: kind,
            action: AymaToastAction(label: 'Retry', onPressed: () {}),
          );
          await tester.pumpAndSettle();
          final ac = theme.extension<AymaTokens>()!;
          final icon = tester.widget<Icon>(
              find.descendant(of: _toast, matching: find.byType(Icon)));
          expect(AymaToastCard.contrast(icon.color!, ac.bgElev),
              greaterThanOrEqualTo(3));
          final button = tester.widget<TextButton>(
              find.descendant(of: _toast, matching: find.byType(TextButton)));
          final fg = button.style!.foregroundColor!.resolve({})!;
          expect(AymaToastCard.contrast(fg, ac.bgElev),
              greaterThanOrEqualTo(4.5));
          final msg = tester.widget<Text>(find.text('Message'));
          expect(AymaToastCard.contrast(msg.style!.color!, ac.bgElev),
              greaterThanOrEqualTo(4.5));
        }
        AymaToast.hide();
        await tester.pumpAndSettle();
      });
    }
  }

  // Jobs pass cluster 20 — defects 10, 11, 12 (spacing/color, no behavior).
  // Themes are built INSIDE each body so the google_fonts asset load happens
  // under the test binding, never at collection time.
  for (final dark in [false, true]) {
    final label = dark ? 'dark' : 'light';
    ThemeData theme() => dark ? AymaTheme.dark : AymaTheme.light;

    testWidgets('$label: toast card sits 20 from each screen edge (defect 10)',
        (tester) async {
      await _pump(tester, theme: theme());
      AymaToast.show(_ctx(tester), 'Saved', kind: AymaToastKind.success);
      await tester.pumpAndSettle();
      final positioned = tester.widget<Positioned>(
          find.ancestor(of: _toast, matching: find.byType(Positioned)).first);
      expect(positioned.left, 20);
      expect(positioned.right, 20);
      AymaToast.hide();
      await tester.pumpAndSettle();
    });

    testWidgets('$label: toast card border reads boundary (defect 11)',
        (tester) async {
      final t = theme();
      await _pump(tester, theme: t);
      AymaToast.show(_ctx(tester), 'Saved', kind: AymaToastKind.success);
      await tester.pumpAndSettle();
      final ac = t.extension<AymaTokens>()!;
      final bordered = tester
          .widgetList<Container>(
              find.descendant(of: _toast, matching: find.byType(Container)))
          .firstWhere((c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).border != null);
      final side = ((bordered.decoration as BoxDecoration).border as Border).top;
      expect(side.color, ac.boundary);
      AymaToast.hide();
      await tester.pumpAndSettle();
    });

    testWidgets('$label: toast kind label renders mono 10 (defect 12)',
        (tester) async {
      await _pump(tester, theme: theme());
      AymaToast.show(_ctx(tester), 'Saved', kind: AymaToastKind.success);
      await tester.pumpAndSettle();
      final labelText = tester.widget<Text>(find.text('DONE'));
      expect(labelText.style!.fontSize, 10);
      AymaToast.hide();
      await tester.pumpAndSettle();
    });
  }
}
