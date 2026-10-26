import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// One device/window/accessibility configuration the layout matrix pumps a
/// surface at. Sizes are logical pixels (the matrix runs at a device pixel
/// ratio of 1, which changes nothing about layout and keeps it fast).
class LayoutCase {
  const LayoutCase(
    this.width,
    this.height, {
    this.textScale = 1.0,
    this.dark = true,
    this.keyboard = 0,
    this.top = 24,
    this.bottom = 24,
    this.rtl = false,
    this.bold = false,
    this.highContrast = false,
    this.accent,
  });

  final double width;
  final double height;
  final double textScale;
  final bool dark;

  /// On-screen keyboard height (bottom view inset).
  final double keyboard;

  /// Status bar / display cutout inset.
  final double top;

  /// System navigation inset: 24 for gesture nav, 48 for 3-button nav.
  final double bottom;
  final bool rtl;
  final bool bold;
  final bool highContrast;

  /// A non-default accent colour, or null for the app default.
  final Color? accent;

  @override
  String toString() => [
    '${width.toInt()}x${height.toInt()}',
    'text ${textScale}x',
    dark ? 'dark' : 'light',
    if (keyboard > 0) 'keyboard ${keyboard.toInt()}',
    'insets ${top.toInt()}/${bottom.toInt()}',
    if (rtl) 'rtl',
    if (bold) 'bold',
    if (highContrast) 'high-contrast',
    if (accent != null) 'accent',
  ].join(', ');
}

/// The full matrix: phones from the 320x568 floor up, the Pixel Fold's cover
/// (412x915) and near-square inner display (~791x820 logical for its
/// 2076x2152 panel), tablets, landscape/rotation, split-screen and freeform
/// windows down to 300px tall, text scale 1.0/1.5/2.0, keyboard open,
/// gesture vs 3-button nav, a tall cutout, RTL, bold text, high contrast,
/// light/dark and a non-default accent. The sequence is pumped in order on
/// ONE live widget tree, so it also exercises resizing/rotation of a mounted
/// screen (state kept), the way a foldable or freeform window does.
const kLayoutMatrix = <LayoutCase>[
  LayoutCase(390, 844),
  LayoutCase(320, 568),
  LayoutCase(360, 640, bottom: 48),
  LayoutCase(412, 915),
  LayoutCase(600, 960),
  LayoutCase(840, 1200),
  LayoutCase(791, 820, top: 48),
  LayoutCase(2076, 2152),
  // Rotation / landscape.
  LayoutCase(844, 390, top: 0, bottom: 21),
  LayoutCase(568, 320, top: 0),
  LayoutCase(915, 412, top: 0, bottom: 48),
  LayoutCase(1200, 840, top: 0),
  // Split-screen and freeform windows.
  LayoutCase(412, 300, top: 0, bottom: 0),
  LayoutCase(791, 300, top: 0),
  LayoutCase(320, 300, top: 0, bottom: 0),
  LayoutCase(360, 420, top: 0),
  // Large text.
  LayoutCase(390, 844, textScale: 2.0),
  LayoutCase(320, 568, textScale: 2.0),
  LayoutCase(360, 640, textScale: 1.5, bottom: 48),
  LayoutCase(791, 820, textScale: 1.5),
  LayoutCase(844, 390, textScale: 2.0, top: 0),
  LayoutCase(412, 300, textScale: 2.0, top: 0, bottom: 0),
  LayoutCase(320, 300, textScale: 1.5, top: 0, bottom: 0),
  // On-screen keyboard open.
  LayoutCase(390, 844, keyboard: 336),
  LayoutCase(320, 568, keyboard: 260, textScale: 1.5),
  LayoutCase(412, 915, keyboard: 320, textScale: 2.0, bottom: 48),
  LayoutCase(844, 390, keyboard: 200, top: 0),
  LayoutCase(791, 820, keyboard: 330),
  // Light theme, accessibility, RTL, accent.
  LayoutCase(390, 844, dark: false),
  LayoutCase(320, 568, dark: false, textScale: 2.0, bold: true),
  LayoutCase(360, 640, dark: false, rtl: true, textScale: 1.5),
  LayoutCase(412, 915, highContrast: true, bold: true, accent: Colors.teal),
  LayoutCase(568, 320, dark: false, top: 0, rtl: true),
];

bool _isIgnorable(FlutterErrorDetails d) {
  // A fake HTTP client answers image URLs with an error: the image widgets'
  // own fallbacks handle that in-app, and it says nothing about layout.
  final s = '${d.exception}';
  return d.library == 'image resource service' ||
      s.contains('NetworkImageLoadException') ||
      s.contains('HttpException') ||
      s.contains('Invalid image data');
}

/// The "relevant error-causing widget" location Flutter attaches to layout
/// errors, so a failure names the exact widget and line to fix.
String _culprit(FlutterErrorDetails details) {
  final lines = details.toString().split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].contains('relevant error-causing widget was')) {
      final where = lines
          .skip(i + 1)
          .take(2)
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .join(' ')
          .replaceAll(RegExp(r'file://\S*/ayma_flutter/'), '');
      return ' <- $where';
    }
  }
  return '';
}

/// Pumps [build] (wrapped in a themed [MaterialApp]) through every
/// [LayoutCase] in [cases] and fails if any case reports a RenderFlex
/// overflow, an unbounded-constraint error or any other exception.
///
/// [open] runs once after the first frame with a context under the app's
/// Navigator — the hook for showing a sheet, dialog or toast over the screen
/// so the overlay itself is what the matrix measures.
Future<void> expectLayoutRobust(
  WidgetTester tester,
  Widget Function() build, {
  List<LayoutCase> cases = kLayoutMatrix,
  Future<void> Function(BuildContext context)? open,
  Duration settle = const Duration(milliseconds: 400),
}) async {
  final errors = <String>[];
  var current = cases.first;
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (_isIgnorable(details)) return;
    final first = details.exceptionAsString().split('\n').first;
    errors.add('[$current] $first${_culprit(details)}');
  };
  final config = ValueNotifier<LayoutCase>(current);
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearAllTestValues();
  });

  void apply(LayoutCase c) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(c.width, c.height);
    // As on a device, the keyboard covers the bottom system inset.
    tester.view.padding = FakeViewPadding(
      top: c.top,
      bottom: c.keyboard > 0 ? 0 : c.bottom,
    );
    tester.view.viewPadding = FakeViewPadding(top: c.top, bottom: c.bottom);
    tester.view.viewInsets = FakeViewPadding(bottom: c.keyboard);
    tester.platformDispatcher.textScaleFactorTestValue = c.textScale;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(boldText: c.bold, highContrast: c.highContrast);
    config.value = c;
  }

  try {
    // Each case mounts a FRESH tree: a RenderFlex reports its overflow only
    // once per lifetime (`DebugOverflowIndicatorMixin`), so reusing one tree
    // across cases would hide every overflow after the first.
    for (var i = 0; i < cases.length; i++) {
      current = cases[i];
      apply(current);
      final navKey = GlobalKey<NavigatorState>();
      // A real GoRouter, as in the app: screens call `context.go/push`.
      final router = GoRouter(
        navigatorKey: navKey,
        routes: [GoRoute(path: '/', builder: (_, _) => build())],
        errorBuilder: (_, _) => const SizedBox.shrink(),
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<LayoutCase>(
          key: ValueKey(i),
          valueListenable: config,
          builder: (context, c, _) => MaterialApp.router(
            routerConfig: router,
            debugShowCheckedModeBanner: false,
            theme: c.accent == null
                ? AymaTheme.light
                : AymaTheme.lightWithAccent(c.accent!),
            darkTheme: c.accent == null
                ? AymaTheme.dark
                : AymaTheme.darkWithAccent(c.accent!),
            themeMode: c.dark ? ThemeMode.dark : ThemeMode.light,
            builder: (context, appChild) => Directionality(
              textDirection: c.rtl ? TextDirection.rtl : TextDirection.ltr,
              child: AymaToastHost(child: appChild!),
            ),
          ),
        ),
      );
      await tester.pump(settle);
      if (open != null) {
        final label = '$current';
        // Not awaited: the overlay's Future completes only when it closes.
        open(navKey.currentContext!).catchError(
          (Object e) => errors.add('[$label] open: $e'),
        );
        await tester.pump();
        await tester.pump(settle);
      }
      // Unmount inside the guarded window so dispose-time errors count too.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 1));
  } finally {
    FlutterError.onError = previous;
  }
  final unique = errors.toSet().toList();
  expect(
    unique,
    isEmpty,
    reason: 'Layout errors (${unique.length}):\n${unique.take(25).join('\n')}',
  );
}
