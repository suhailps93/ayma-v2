import 'package:ayma_flutter/services/feature_tour_store.dart';
import 'package:ayma_flutter/services/tour_anchors.dart';
import 'package:ayma_flutter/services/tour_content.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:ayma_flutter/widgets/chat_composer.dart';
import 'package:ayma_flutter/widgets/coach_mark_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory store double — no Firebase. Records what the engine marks seen.
class _FakeTourStore extends FeatureTourStore {
  final Set<String> seen = {};
  List<String>? lastMarked;

  @override
  Future<Set<String>> loadSeen() async => seen;

  @override
  Future<void> markSeen(Iterable<String> ids) async {
    lastMarked = ids.toList();
    seen.addAll(ids);
  }

  @override
  Future<void> reset() async => seen.clear();
}

// Step A anchors a real (dummy) widget; step B points at an anchor nothing
// mounts (must skip); step C is a centered closer (no anchor).
const _features = <TourFeature>[
  TourFeature(
    featureId: 'a',
    headline: 'Alpha',
    subtitle: 'first',
    anchorId: TourAnchors.homeOrb,
  ),
  TourFeature(
    featureId: 'b',
    headline: 'Bravo',
    subtitle: 'second',
    anchorId: 'ghost_anchor_never_mounted',
  ),
  TourFeature(
    featureId: 'c',
    headline: 'Charlie',
    subtitle: 'third',
    icon: Icons.star_rounded,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host({
    required FeatureTourStore store,
    required VoidCallback onFinish,
    List<TourFeature> features = _features,
    bool spotlight = false,
    bool reducedMotion = false,
  }) {
    return MaterialApp(
      theme: AymaTheme.dark,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
          child: Scaffold(
            body: Stack(
              children: [
                // A real target near the bottom for step A's spotlight.
                Positioned(
                  left: 24,
                  bottom: 24,
                  child: SizedBox(
                    key: TourAnchors.keyFor(TourAnchors.homeOrb),
                    width: 64,
                    height: 64,
                  ),
                ),
                Positioned.fill(
                  child: CoachMarkOverlay(
                    store: store,
                    onFinish: onFinish,
                    features: features,
                    spotlight: spotlight,
                    // A missing anchor should skip within a few pumps here (the
                    // on-device default is generous, to ride out transitions).
                    maxMeasureAttempts: 3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Pumped WITHOUT `pumpAndSettle`: the spotlight ring pulses forever, so
  // settling would hang. Explicit frame pumps instead — several, because the
  // engine measures each step in a post-frame callback (and a skipped
  // missing-target step chains one more), then flips `_ready` on the next.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> advance(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('coach-next')));
    await settle(tester);
  }

  testWidgets('spotlights the target by key and shows its copy', (tester) async {
    await tester.pumpWidget(host(store: _FakeTourStore(), onFinish: () {}));
    await settle(tester);

    // The scrim/spotlight layer is painted, and the first step's copy shows.
    expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('1 of 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-next')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-skip')), findsOneWidget);
  });

  testWidgets('Next advances, and a missing-target step is skipped without '
      'crashing', (tester) async {
    await tester.pumpWidget(host(store: _FakeTourStore(), onFinish: () {}));
    await settle(tester);

    expect(find.text('Alpha'), findsOneWidget);
    await advance(tester);

    // Step B (anchor never mounted) is skipped — we land on Charlie, and Bravo
    // never renders.
    expect(find.text('Bravo'), findsNothing);
    expect(find.text('Charlie'), findsOneWidget);
    // Last step: the CTA reads "Done" (not "Next"-only framing changes).
    expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
  });

  testWidgets('completing the last step marks every shown feature seen and '
      'finishes', (tester) async {
    final store = _FakeTourStore();
    var finished = 0;
    await tester.pumpWidget(host(store: store, onFinish: () => finished++));
    await settle(tester);

    await advance(tester); // A -> (B skipped) -> C
    expect(find.text('Charlie'), findsOneWidget);
    expect(store.seen, isEmpty);

    await tester.tap(find.byKey(const ValueKey('coach-next'))); // Done
    await tester.pump();
    await settle(tester);

    expect(store.seen, {'a', 'b', 'c'});
    expect(finished, 1);
  });

  testWidgets('Skip exits and marks every feature seen', (tester) async {
    final store = _FakeTourStore();
    var finished = 0;
    await tester.pumpWidget(host(store: store, onFinish: () => finished++));
    await settle(tester);

    expect(store.seen, isEmpty);
    await tester.tap(find.byKey(const ValueKey('coach-skip')));
    await tester.pump();
    await settle(tester);

    expect(store.seen, {'a', 'b', 'c'});
    expect(finished, 1);
  });

  testWidgets('spotlight mode shows the NEW framing and a Got it CTA', (
    tester,
  ) async {
    const only = [
      TourFeature(
        featureId: 'c',
        headline: 'Charlie',
        subtitle: 'third',
        icon: Icons.star_rounded,
      ),
    ];
    await tester.pumpWidget(host(
      store: _FakeTourStore(),
      onFinish: () {},
      features: only,
      spotlight: true,
    ));
    await settle(tester);

    expect(find.text('NEW'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Got it'), findsOneWidget);
  });

  testWidgets(
      'spotlight mode: Got it button dismisses the popup and marks seen on tap',
      (tester) async {
    final store = _FakeTourStore();
    var finished = 0;
    const voiceStep = [
      TourFeature(
        featureId: 'async_voice',
        headline: 'Voice messages',
        subtitle: 'Hold the mic, speak, release',
        anchorId: TourAnchors.homeOrb,
      ),
    ];
    await tester.pumpWidget(host(
      store: store,
      onFinish: () => finished++,
      features: voiceStep,
      spotlight: true,
    ));
    await settle(tester);

    expect(find.text('NEW'), findsOneWidget);
    expect(find.text('Voice messages'), findsOneWidget);
    final gotIt = find.widgetWithText(FilledButton, 'Got it');
    expect(gotIt, findsOneWidget);

    // Verify Semantics values for accessibility tree
    final nextSemantics =
        tester.getSemantics(find.byKey(const ValueKey('coach-next')));
    expect(nextSemantics.label, 'Got it');
    expect(
      nextSemantics.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );

    await tester.tap(gotIt);
    await tester.pump();
    await settle(tester);

    expect(finished, 1);
    expect(store.seen, {'async_voice'});
  });

  testWidgets(
      'spotlight mode: Skip tour button dismisses the popup on tap',
      (tester) async {
    final store = _FakeTourStore();
    var finished = 0;
    const voiceStep = [
      TourFeature(
        featureId: 'async_voice',
        headline: 'Voice messages',
        subtitle: 'Hold the mic, speak, release',
        anchorId: TourAnchors.homeOrb,
      ),
    ];
    await tester.pumpWidget(host(
      store: store,
      onFinish: () => finished++,
      features: voiceStep,
      spotlight: true,
    ));
    await settle(tester);

    final skip = find.byKey(const ValueKey('coach-skip'));
    expect(skip, findsOneWidget);

    // Verify Semantics values for accessibility tree
    final skipSemantics = tester.getSemantics(skip);
    expect(skipSemantics.label, 'Skip tour');
    expect(
      skipSemantics.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );

    await tester.tap(skip);
    await tester.pump();
    await settle(tester);

    expect(finished, 1);
    expect(store.seen, {'async_voice'});
  });

  // A host that layers the overlay over a tappable anchor and a full-screen
  // background sensor, mirroring the real shell (overlay as a sibling above the
  // app) so press-through hit testing behaves the same.
  Widget pressHost({
    required FeatureTourStore store,
    required VoidCallback onAnchorTap,
    required VoidCallback onBgTap,
  }) {
    return MaterialApp(
      theme: AymaTheme.dark,
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onBgTap,
              ),
            ),
            Positioned(
              left: 24,
              bottom: 24,
              child: GestureDetector(
                key: TourAnchors.keyFor(TourAnchors.homeOrb),
                behavior: HitTestBehavior.opaque,
                onTap: onAnchorTap,
                child: const SizedBox(width: 64, height: 64),
              ),
            ),
            Positioned.fill(
              child: CoachMarkOverlay(
                store: store,
                onFinish: () {},
                features: _features,
                maxMeasureAttempts: 3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('tapping the cutout presses through to the real widget AND '
      'advances the tour', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var anchorTaps = 0;
    var bgTaps = 0;
    await tester.pumpWidget(pressHost(
      store: _FakeTourStore(),
      onAnchorTap: () => anchorTaps++,
      onBgTap: () => bgTaps++,
    ));
    await settle(tester);
    expect(find.text('Alpha'), findsOneWidget);

    // Tap the spotlighted anchor (bottom-left 64x64 box, centered).
    await tester.tapAt(const Offset(56, 544));
    await settle(tester);

    // The real widget behind the cutout received the tap (press-through)...
    expect(anchorTaps, 1);
    expect(bgTaps, 0);
    // ...and the tour advanced (A -> B skipped -> Charlie).
    expect(find.text('Charlie'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
  });

  testWidgets('tapping the dimmed scrim is absorbed — no press-through, no '
      'advance', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var anchorTaps = 0;
    var bgTaps = 0;
    await tester.pumpWidget(pressHost(
      store: _FakeTourStore(),
      onAnchorTap: () => anchorTaps++,
      onBgTap: () => bgTaps++,
    ));
    await settle(tester);
    expect(find.text('Alpha'), findsOneWidget);

    // Tap far from the cutout (bottom-left) and the callout (top) — pure scrim.
    await tester.tapAt(const Offset(700, 300));
    await settle(tester);

    expect(bgTaps, 0); // blocked by the scrim
    expect(anchorTaps, 0);
    expect(find.text('Alpha'), findsOneWidget); // did not advance
  });

  // Scout note 118 leg 4: on the composer step the tour must let the user tap
  // the text field and type (or press Send) without stealing focus or advancing.
  // Only the mic is an anchor tap; Done / Skip still move the tour forward.
  const typingFeatures = <TourFeature>[
    TourFeature(
      featureId: 'typing',
      headline: 'Type here',
      subtitle: 'say hi to Ayma',
      anchorId: TourAnchors.homeComposer,
      typingAllowed: true,
    ),
    TourFeature(
      featureId: 'after_typing',
      headline: 'Next step',
      subtitle: 'moved on',
    ),
  ];

  Widget typingHost({
    required FeatureTourStore store,
    required FocusNode focusNode,
    required VoidCallback onAnchorTap,
    required VoidCallback onSendTap,
    required VoidCallback onAttachTap,
    VoidCallback? onMicTap,
    bool driven = true,
  }) {
    return MaterialApp(
      theme: AymaTheme.dark,
      home: Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Column(
                key: TourAnchors.keyFor(TourAnchors.homeComposer),
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const ValueKey('composer-field'),
                    focusNode: focusNode,
                  ),
                  Row(
                    children: [
                      GestureDetector(
                        key: TourAnchors.keyFor(TourAnchors.asyncVoiceMic),
                        behavior: HitTestBehavior.opaque,
                        onTap: onMicTap,
                        child: const SizedBox(
                          width: 48,
                          height: 48,
                          child: Icon(Icons.mic),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        key: const ValueKey('composer-send'),
                        behavior: HitTestBehavior.opaque,
                        onTap: onSendTap,
                        child: const SizedBox(
                          width: 48,
                          height: 48,
                          child: Icon(Icons.send),
                        ),
                      ),
                      GestureDetector(
                        key: const ValueKey('composer-attach'),
                        behavior: HitTestBehavior.opaque,
                        onTap: onAttachTap,
                        child: const SizedBox(
                          width: 48,
                          height: 48,
                          child: Icon(Icons.add_photo_alternate_outlined),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Positioned.fill(
              child: CoachMarkOverlay(
                store: store,
                onFinish: () {},
                features: typingFeatures,
                maxMeasureAttempts: 3,
                onAnchorTapped: driven ? onAnchorTap : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('typing-allowed step: tapping the text field keeps focus and '
      'does not fire onTapped', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var anchorTaps = 0;
    await tester.pumpWidget(typingHost(
      store: _FakeTourStore(),
      focusNode: focus,
      onAnchorTap: () => anchorTaps++,
      onSendTap: () {},
      onAttachTap: () {},
    ));
    await settle(tester);
    expect(find.text('Type here'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('composer-field')));
    await tester.pump();

    expect(focus.hasFocus, isTrue);
    expect(anchorTaps, 0);
    expect(find.text('Type here'), findsOneWidget);
    expect(find.text('Next step'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('composer-field')),
      'hello Ayma',
    );
    await tester.pump();
    expect(anchorTaps, 0);
    expect(find.text('Type here'), findsOneWidget);
  });

  testWidgets('typing-allowed step: Send and Attach press through but do not '
      'advance the tour', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var anchorTaps = 0;
    var sends = 0;
    var attaches = 0;
    await tester.pumpWidget(typingHost(
      store: _FakeTourStore(),
      focusNode: focus,
      onAnchorTap: () => anchorTaps++,
      onSendTap: () => sends++,
      onAttachTap: () => attaches++,
    ));
    await settle(tester);

    // Send is press-through — it acts on the real composer — but it is not an
    // anchor tap, so the tour stays on the composer step.
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await settle(tester);
    expect(sends, 1);
    expect(anchorTaps, 0);
    expect(find.text('Type here'), findsOneWidget);

    // Same for Attach.
    await tester.tap(find.byKey(const ValueKey('composer-attach')));
    await settle(tester);
    expect(attaches, 1);
    expect(anchorTaps, 0);
    expect(find.text('Type here'), findsOneWidget);
  });

  // Scout note 123, F2: the mic tap advances the tour (onTapped fires)
  // but must be CONSUMED — the mic's own tap action (in the real app,
  // starting a live voice call) must never fire during the tour.
  testWidgets('typing-allowed step: tapping the mic fires onTapped but is '
      'consumed — the mic action never runs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var anchorTaps = 0;
    var micTaps = 0;
    await tester.pumpWidget(typingHost(
      store: _FakeTourStore(),
      focusNode: focus,
      onAnchorTap: () => anchorTaps++,
      onSendTap: () {},
      onAttachTap: () {},
      onMicTap: () => micTaps++,
    ));
    await settle(tester);

    // warnIfMissed is off for every mic tap in this file on purpose: F2
    // consumes the tap in the overlay, so the mic widget is never hit.
    await tester.tap(find.byKey(TourAnchors.keyFor(TourAnchors.asyncVoiceMic)), warnIfMissed: false);
    await tester.pump();

    expect(anchorTaps, 1);
    expect(micTaps, 0);
  });

  testWidgets('typing-allowed step: the mic advances the passive tour '
      'without its own action firing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var micTaps = 0;
    await tester.pumpWidget(typingHost(
      store: _FakeTourStore(),
      focusNode: focus,
      onAnchorTap: () {},
      onSendTap: () {},
      onAttachTap: () {},
      onMicTap: () => micTaps++,
      driven: false,
    ));
    await settle(tester);
    expect(find.text('Type here'), findsOneWidget);

    // A text-field tap leaves the tour where it is...
    await tester.tap(find.byKey(const ValueKey('composer-field')));
    await settle(tester);
    expect(find.text('Type here'), findsOneWidget);

    // ...the mic moves it on, and the mic itself never acts (F2).
    await tester.tap(find.byKey(TourAnchors.keyFor(TourAnchors.asyncVoiceMic)), warnIfMissed: false);
    await settle(tester);
    expect(find.text('Next step'), findsOneWidget);
    expect(micTaps, 0);
  });

  // Scout note 123, F2 on the mic step itself (anchor = the mic, not a
  // typing-allowed composer): the tap advances the tour and is consumed,
  // so the mic's tap action — a live voice call in the real app — never
  // starts mid-tour.
  testWidgets('mic step: tapping the mic advances the tour but does not '
      'invoke the mic action', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var micTaps = 0;
    const micFeatures = <TourFeature>[
      TourFeature(
        featureId: 'mic_step',
        headline: 'Mic step',
        subtitle: 'tap the mic',
        anchorId: TourAnchors.asyncVoiceMic,
      ),
      TourFeature(
        featureId: 'after_mic',
        headline: 'After mic',
        subtitle: 'moved on',
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.dark,
      home: Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: 16,
              bottom: 16,
              child: GestureDetector(
                key: TourAnchors.keyFor(TourAnchors.asyncVoiceMic),
                behavior: HitTestBehavior.opaque,
                onTap: () => micTaps++,
                child: const SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(Icons.mic),
                ),
              ),
            ),
            Positioned.fill(
              child: CoachMarkOverlay(
                store: _FakeTourStore(),
                onFinish: () {},
                features: micFeatures,
                maxMeasureAttempts: 3,
              ),
            ),
          ],
        ),
      ),
    ));
    await settle(tester);
    expect(find.text('Mic step'), findsOneWidget);

    await tester.tap(find.byKey(TourAnchors.keyFor(TourAnchors.asyncVoiceMic)), warnIfMissed: false);
    await settle(tester);

    expect(find.text('After mic'), findsOneWidget);
    expect(micTaps, 0);
  });

  testWidgets('typing-allowed step: the spotlight follows the composer when '
      'the keyboard opens', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var anchorTaps = 0;
    await tester.pumpWidget(typingHost(
      store: _FakeTourStore(),
      focusNode: focus,
      onAnchorTap: () => anchorTaps++,
      onSendTap: () {},
      onAttachTap: () {},
    ));
    await settle(tester);

    final before = TourAnchors.rectFor(TourAnchors.asyncVoiceMic);
    expect(before, isNotNull);

    // Keyboard opens: the Scaffold shrinks and lifts the composer. The stale
    // cutout would leave the mic outside the press-through hole.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await settle(tester);

    final after = TourAnchors.rectFor(TourAnchors.asyncVoiceMic);
    expect(after, isNotNull);
    expect(after!.top, lessThan(before!.top));

    await tester.tap(find.byKey(TourAnchors.keyFor(TourAnchors.asyncVoiceMic)), warnIfMissed: false);
    await tester.pump();
    expect(anchorTaps, 1);
  });

  testWidgets('reduced motion renders without crashing', (tester) async {
    await tester.pumpWidget(
      host(store: _FakeTourStore(), onFinish: () {}, reducedMotion: true),
    );
    await settle(tester);

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
  });

  // Bug A regression: the `home_orb` anchor must resolve to the real centre
  // ORB, not one of the tab icon buttons (the Messages/envelope icon). The
  // shell hands `AymaTabBar` its tour anchor keys by tab index; tab 0 is the
  // orb, tab 2 the Messages icon.
  testWidgets('home_orb anchor is on the orb, not a tab icon', (tester) async {
    final anchorKeys = <int, GlobalKey>{
      0: TourAnchors.keyFor(TourAnchors.homeOrb),
      1: TourAnchors.keyFor(TourAnchors.exploreTab),
      2: TourAnchors.keyFor(TourAnchors.messagesTab),
      3: TourAnchors.keyFor(TourAnchors.profileTab),
      AymaTabBar.kBellAnchor: TourAnchors.keyFor(TourAnchors.notificationsBell),
    };
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.dark,
      home: Scaffold(
        bottomNavigationBar: AymaTabBar(
          index: 0,
          voice: null,
          onSelected: (_) {},
          anchorKeys: anchorKeys,
        ),
      ),
    ));
    await tester.pump();

    // The orb key wraps the real AymaOrb...
    expect(
      find.descendant(
        of: find.byKey(TourAnchors.keyFor(TourAnchors.homeOrb)),
        matching: find.byType(AymaOrb),
      ),
      findsOneWidget,
    );
    // ...and the Messages/envelope key does NOT (it's a different element).
    expect(
      find.descendant(
        of: find.byKey(TourAnchors.keyFor(TourAnchors.messagesTab)),
        matching: find.byType(AymaOrb),
      ),
      findsNothing,
    );
    // The resolved rects are distinct and the orb sits to the right of the
    // Messages icon (it's the visual centre of the bar).
    final orbRect = TourAnchors.rectFor(TourAnchors.homeOrb);
    final messagesRect = TourAnchors.rectFor(TourAnchors.messagesTab);
    expect(orbRect, isNotNull);
    expect(messagesRect, isNotNull);
    expect(orbRect == messagesRect, isFalse);
    expect(orbRect!.center.dx, greaterThan(messagesRect!.center.dx));
  });

  group('performed step on a live call', () {
    Widget overlayOver(Widget page) => Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          Positioned.fill(child: page),
          Positioned.fill(
            child: Theme(
              data: AymaTheme.dark,
              child: CoachMarkOverlay(
                store: _FakeTourStore(),
                onFinish: () {},
                features: const [
                  TourFeature(featureId: 'c', headline: 'C', subtitle: 'c'),
                ],
                pressThrough: false,
                performed: true,
                protectVoiceControls: true,
                hideNextButton: true,
              ),
            ),
          ),
        ],
      ),
    );

    testWidgets('a tap on the real nav-bar orb never reaches it, the tabs do',
        (tester) async {
      final selected = <int>[];
      await tester.pumpWidget(overlayOver(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          // At the top, clear of the card that sits at the bottom.
          body: Align(
            alignment: Alignment.topCenter,
            child: AymaTabBar(
              index: 1,
              voice: null,
              onSelected: selected.add,
            ),
          ),
        ),
      )));
      await settle(tester);

      await tester.tap(find.byType(AymaOrb), warnIfMissed: false);
      await settle(tester);
      expect(selected, isEmpty);

      await tester.tap(find.byIcon(Icons.mail_outline_rounded));
      await settle(tester);
      expect(selected, [2]);
    });

    testWidgets('End voice and Mute on the real call bar never fire',
        (tester) async {
      var stops = 0;
      var mutes = 0;
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      final level = ValueNotifier<double>(0);
      await tester.pumpWidget(overlayOver(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              height: 56,
              child: ChatComposer(
                mode: ComposerMode.listening,
                controller: controller,
                focusNode: focus,
                canSend: false,
                onSend: () {},
                onAttach: () {},
                onMicPressed: () {},
                onStopPressed: () => stops++,
                onMuteTap: () => mutes++,
                muted: false,
                userAmplitude: level,
                aiAmplitude: level,
                statusLabel: 'Listening',
              ),
            ),
          ),
        ),
      )));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.stop_rounded), warnIfMissed: false);
      await tester.tap(find.byIcon(Icons.mic_rounded), warnIfMissed: false);
      await settle(tester);

      expect(stops, 0);
      expect(mutes, 0);
    });
  });

  // Bug B regression: the overlay is hosted ABOVE the Navigator, so a route
  // pushed while the tour is up must NOT tear the callout down — it stays open
  // across pages (founder's "the pop-up goes away when you click to a different
  // page").
  testWidgets('the callout persists across a route push', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.dark,
      navigatorKey: nav,
      // Mirrors `TourHost`: the overlay is a sibling ABOVE the Navigator.
      builder: (context, child) => Stack(
        children: [
          child!,
          Positioned.fill(
            child: CoachMarkOverlay(
              store: _FakeTourStore(),
              onFinish: () {},
              features: const [
                TourFeature(
                  featureId: 'c',
                  headline: 'Charlie',
                  subtitle: 'third',
                  icon: Icons.star_rounded,
                ),
              ],
              maxMeasureAttempts: 3,
            ),
          ),
        ],
      ),
      home: const Scaffold(body: Center(child: Text('Page one'))),
    ));
    await settle(tester);
    expect(find.text('Charlie'), findsOneWidget);
    expect(find.text('Page one'), findsOneWidget);

    // Push a second page on top of the Navigator.
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('Page two'))),
      ),
    );
    await settle(tester);

    // The new page is up AND the floating callout is still open over it.
    expect(find.text('Page two'), findsOneWidget);
    expect(find.text('Charlie'), findsOneWidget);
  });

  // Bug C regression: the callout must not overflow at text scale 2.0 on the
  // smallest supported window — it scrolls/wraps instead.
  testWidgets('callout renders without overflow at text scale 2.0',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.dark,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 24,
                  bottom: 24,
                  child: SizedBox(
                    key: TourAnchors.keyFor(TourAnchors.homeOrb),
                    width: 64,
                    height: 64,
                  ),
                ),
                Positioned.fill(
                  child: CoachMarkOverlay(
                    store: _FakeTourStore(),
                    onFinish: () {},
                    features: _features,
                    maxMeasureAttempts: 3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await settle(tester);

    expect(find.text('Alpha'), findsOneWidget);
    // No RenderFlex overflow / layout exception was thrown while laying out
    // the callout at 2.0.
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'callout card satisfies jobs pass standards: padding 20, radius 18, '
      'counter in fgDim, skip aligns with copy, button heights >= 48',
      (tester) async {
    await tester.pumpWidget(host(store: _FakeTourStore(), onFinish: () {}));
    await settle(tester);

    // Defect 1: scroll padding is 20 all round
    final scroll =
        tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.padding, const EdgeInsets.all(20));

    // Defect 2: Card corner radius is 18
    final cardContainer = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(Container),
          )
          .first,
    );
    final boxDecoration = cardContainer.decoration as BoxDecoration;
    expect(boxDecoration.borderRadius, BorderRadius.circular(18));

    // Defect 3: Counter "1 of 3" uses fgDim
    final counterText = tester.widget<Text>(find.text('1 of 3'));
    expect(counterText.style?.color, AymaTokens.dark.fgDim);

    // Defect 6 & 7: Button heights >= 48
    final skipSize = tester.getSize(find.byKey(const ValueKey('coach-skip')));
    expect(skipSize.height, greaterThanOrEqualTo(48));

    final nextSize = tester.getSize(find.byKey(const ValueKey('coach-next')));
    expect(nextSize.height, greaterThanOrEqualTo(48));

    // Verify: Skip label left edge aligns with the headline left edge
    final alphaPos = tester.getTopLeft(find.text('Alpha'));
    final skipPos = tester.getTopLeft(find.text('Skip tour'));
    expect(skipPos.dx, equals(alphaPos.dx));
  });

  testWidgets('spotlight mode: NEW label uses fgDim', (tester) async {
    await tester.pumpWidget(
        host(store: _FakeTourStore(), onFinish: () {}, spotlight: true));
    await settle(tester);

    final newLabel = tester.widget<Text>(find.text('NEW'));
    expect(newLabel.style?.color, AymaTokens.dark.fgDim);
  });

  testWidgets(
      'chromeless driven tour: skip button height >= 48 and on-scrim foreground',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: CoachMarkOverlay(
          store: _FakeTourStore(),
          onFinish: () {},
          features: const [
            TourFeature(
              featureId: 'intro',
              headline: 'Intro',
              subtitle: 'centered step',
            ),
          ],
          chromeless: true,
          onStopPressed: () {},
          maxMeasureAttempts: 3,
        ),
      ),
    ));
    await settle(tester);

    // Chromeless mode: NO card, NO next button
    expect(find.byKey(const ValueKey('coach-next')), findsNothing);
    expect(find.text('Intro'), findsNothing);

    // Chromeless skip button exists, height >= 48, and foreground is AymaTokens.dark.fg
    final skipBtn = find.byKey(const ValueKey('coach-skip'));
    expect(skipBtn, findsOneWidget);
    expect(tester.getSize(skipBtn).height, greaterThanOrEqualTo(48));

    final textBtn = tester.widget<TextButton>(skipBtn);
    expect(textBtn.style?.foregroundColor?.resolve({}), AymaTokens.dark.fg);
  });
}
