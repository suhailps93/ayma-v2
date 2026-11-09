import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/guided_tour_controller.dart';
import 'package:ayma_flutter/services/tab_request.dart';
import 'package:ayma_flutter/services/tour_anchors.dart';
import 'package:ayma_flutter/services/tour_content.dart';
import 'package:ayma_flutter/services/tour_controller.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/coach_mark_overlay.dart';
import 'package:ayma_flutter/widgets/tour_host.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ayma_flutter/widgets/voice_control_mark.dart';

/// The Ayma-DRIVEN interactive tour (§11.2b): the backend pushes one step at a
/// time; the client spotlights it with the shared [CoachMarkOverlay] in driven
/// mode and reports shown / absent / tapped / stop back. A tap on the highlight
/// makes Ayma perform the step; only the user's go moves the tour on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Pump frames (never pumpAndSettle — the spotlight ring pulses forever).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  // One driven step wired with counting callbacks, over a real (opaque) anchor
  // control and a full-screen background sensor so press-through hit testing is
  // real: a tap on the spotlighted control is absorbed BY the control (its own
  // onTap fires) and never leaks to the background.
  Widget drivenHost({
    String anchorId = TourAnchors.homeOrb,
    required void Function() onShown,
    required void Function() onAbsent,
    required void Function() onTapped,
    required void Function() onStop,
    required void Function() onBgTap,
    void Function()? onAnchorRealTap,
    int maxMeasureAttempts = 3,
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
                onTap: onAnchorRealTap ?? () {},
                child: const SizedBox(width: 64, height: 64),
              ),
            ),
            Positioned.fill(
              child: CoachMarkOverlay(
                onFinish: () {},
                chromeless: true,
                maxMeasureAttempts: maxMeasureAttempts,
                onAnchorShown: onShown,
                onAnchorAbsent: onAbsent,
                onAnchorTapped: onTapped,
                onStopPressed: onStop,
                features: [
                  TourFeature(
                    featureId: 'guided_tour_step_0',
                    headline: 'Explore',
                    subtitle: 'Now tap Explore to meet people.',
                    anchorId: anchorId,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  group('driven coach-mark engine', () {
    testWidgets('chromeless: ONLY the spotlight (no card), reports shown, and a '
        'real tap presses through AND reports tapped (not a local advance)',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var shown = 0, absent = 0, tapped = 0, stop = 0, bg = 0, realTap = 0;
      await tester.pumpWidget(drivenHost(
        onShown: () => shown++,
        onAbsent: () => absent++,
        onTapped: () => tapped++,
        onStop: () => stop++,
        onBgTap: () => bg++,
        onAnchorRealTap: () => realTap++,
      ));
      await settle(tester);

      // The spotlight is up, but NO feature card: no "NEW" framing, no headline,
      // no description, no step counter, no "Next" (founder 2026-11-03 — the
      // instruction is Ayma's line, not a dialog). Only a tiny "Skip tour".
      expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
      expect(find.text('Explore'), findsNothing); // headline not rendered
      expect(find.text('Now tap Explore to meet people.'), findsNothing);
      expect(find.text('NEW'), findsNothing);
      expect(find.byKey(const ValueKey('coach-next')), findsNothing);
      expect(find.byKey(const ValueKey('coach-skip')), findsOneWidget); // tiny stop
      expect(shown, 1);
      expect(absent, 0);

      // Tap the spotlighted anchor: the press-through lets the REAL control act
      // (its own onTap fires, not the background) AND fires onAnchorTapped —
      // the signal the backend advances on — not a local list advance.
      await tester.tapAt(const Offset(56, 544));
      await settle(tester);
      expect(realTap, 1); // the real control acted (press-through)
      expect(tapped, 1); // the tour recorded the tap
      expect(bg, 0); // never leaked to the background scrim
      expect(stop, 0);
    });

    testWidgets('render callout card (F5): headline, say text, counter, Skip and Next CTAs',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var shown = 0, absent = 0, tapped = 0, stop = 0;
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
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
                  onFinish: () {},
                  chromeless: false,
                  stepIndex: 3,
                  stepTotal: 9,
                  maxMeasureAttempts: 3,
                  onAnchorShown: () => shown++,
                  onAnchorAbsent: () => absent++,
                  onAnchorTapped: () => tapped++,
                  onStopPressed: () => stop++,
                  features: const [
                    TourFeature(
                      featureId: 'guided_tour_step_3',
                      headline: 'Profile Tab',
                      subtitle: 'Tap Profile to customize your story.',
                      anchorId: TourAnchors.homeOrb,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ));
      await settle(tester);

      expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
      expect(find.text('Profile Tab'), findsOneWidget);
      expect(find.text('Tap Profile to customize your story.'), findsOneWidget);
      expect(find.text('4 of 9'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-next')), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-skip')), findsOneWidget);
      expect(shown, 1);
    });

    testWidgets('a missing anchor reports absent (never hangs)', (tester) async {
      var shown = 0, absent = 0, tapped = 0;
      await tester.pumpWidget(drivenHost(
        anchorId: 'ghost_anchor_never_mounted',
        onShown: () => shown++,
        onAbsent: () => absent++,
        onTapped: () => tapped++,
        onStop: () {},
        onBgTap: () {},
      ));
      await settle(tester);
      expect(absent, 1);
      expect(shown, 0);
      expect(tapped, 0);
    });

    testWidgets('Skip tour reports stop (ends the whole guided tour)',
        (tester) async {
      var stop = 0, tapped = 0;
      await tester.pumpWidget(drivenHost(
        onShown: () {},
        onAbsent: () {},
        onTapped: () => tapped++,
        onStop: () => stop++,
        onBgTap: () {},
      ));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('coach-skip')));
      await tester.pump();
      expect(stop, 1);
      expect(tapped, 0);
    });
  });

  group('GuidedTourController', () {
    testWidgets('show starts a session; clearStep keeps the session; endSession '
        'ends it', (tester) async {
      final c = GuidedTourController.instance;
      c.endSession();
      expect(c.active, isFalse);
      expect(c.sessionActive, isFalse);
      c.show(GuidedTourStep(
        token: 't1',
        feature: const TourFeature(
            featureId: 'x', headline: 'H', subtitle: 'S'),
        index: 0,
        total: 1,
        onShown: () {},
        onAbsent: () {},
        onTapped: () {},
        onStop: () {},
      ));
      expect(c.active, isTrue);
      expect(c.sessionActive, isTrue);
      expect(c.step!.token, 't1');
      // A tap clears the step's spotlight but the SESSION stays active (so the
      // passive tour can't slip in before the backend sends the next step).
      c.clearStep();
      expect(c.active, isFalse);
      expect(c.sessionActive, isTrue);
      // Only endSession ends the session.
      c.endSession();
      expect(c.sessionActive, isFalse);
    });

    test('stopFromBack runs the step stop (the backend-visible signal) and '
        'ends the session', () {
      final c = GuidedTourController.instance;
      c.endSession();
      var stopped = 0;
      c.show(GuidedTourStep(
        token: 't1',
        feature: const TourFeature(
            featureId: 'x', headline: 'H', subtitle: 'S'),
        index: 0,
        total: 1,
        onShown: () {},
        onAbsent: () {},
        onTapped: () {},
        // As AppCommandService wires it: report 'stop', then end the session.
        onStop: () {
          stopped++;
          c.endSession();
        },
      ));
      c.stopFromBack();
      expect(stopped, 1);
      expect(c.active, isFalse);
      expect(c.sessionActive, isFalse);
    });

    test('stopFromBack between steps just ends the session (nothing to signal)',
        () {
      final c = GuidedTourController.instance;
      c.endSession();
      c.show(GuidedTourStep(
        token: 't1',
        feature: const TourFeature(
            featureId: 'x', headline: 'H', subtitle: 'S'),
        index: 0,
        total: 2,
        onShown: () {},
        onAbsent: () {},
        onTapped: () {},
        onStop: () {},
      ));
      c.clearStep(); // the tap gap: session alive, no step showing
      expect(c.sessionActive, isTrue);
      c.stopFromBack();
      expect(c.sessionActive, isFalse);
    });
  });

  group('AppCommandService tour_step/tour_end (full client loop)', () {
    // A host that watches GuidedTourController and renders the driven overlay
    // exactly as TourHost does, minus the appRouter prepare-step (so the test
    // needs no router). An anchor + background sensor make press-through real.
    Widget controllerHost() {
      return MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          body: AnimatedBuilder(
            animation: GuidedTourController.instance,
            builder: (context, _) {
              final step = GuidedTourController.instance.step;
              return Stack(
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
                  if (step != null)
                    Positioned.fill(
                      child: CoachMarkOverlay(
                        key: ValueKey('guided-tour-${step.token}'),
                        features: [step.feature],
                        stepIndex: step.index,
                        stepTotal: step.total,
                        chromeless: false,
                        maxMeasureAttempts: 3,
                        onFinish: GuidedTourController.instance.endSession,
                        onAnchorShown: step.onShown,
                        onAnchorAbsent: step.onAbsent,
                        onAnchorTapped: step.onTapped,
                        onSkipPressed: step.onSkip,
                        onStopPressed: step.onStop,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
    }

    late FakeFirebaseFirestore fake;
    late AppCommandService svc;
    late DocumentReference<Map<String, dynamic>> pending;
    late List<int> tourPings;
    late List<int> stopPings;

    setUp(() async {
      GuidedTourController.instance.endSession();
      AppContext.instance.current.value = const ScreenContext();
      VoiceSessionController.active = null; // no live call → text bridge path
      fake = FakeFirebaseFirestore();
      tourPings = <int>[];
      stopPings = <int>[];
      svc = AppCommandService(
        firestore: fake,
        auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')),
        // The TEXT tap bridge: on a tap with no live voice call, the service
        // fires a /chat continuation that makes the model advance the tour.
        sendTourContinuation: (index) async => tourPings.add(index),
        sendTourStop: (index) async => stopPings.add(index),
      );
      pending = fake.doc('users/u1/app_commands/pending');
    });

    testWidgets('a tour_step spotlights the anchor and acks ok:true; a real tap '
        'writes a tapped tour_event', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(controllerHost());

      final cmd = <String, dynamic>{
        'action': 'tour_step',
        'id': 'c1',
        'index': 0,
        'total': 9,
        'anchor': TourAnchors.homeOrb,
        'headline': 'Explore',
        'say': 'Now tap Explore to meet people.',
      };
      await pending.set(cmd);
      svc.runTourStep(pending, cmd, id: 'c1');
      await settle(tester);

      // The spotlight is up and the callout card renders (F5) with headline,
      // say text, step counter, skip tour and next button. The step was acked
      // as shown. The session is active.
      expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
      expect(find.text('Explore'), findsOneWidget);
      expect(find.text('Now tap Explore to meet people.'), findsOneWidget);
      expect(find.text('1 of 9'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-next')), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-skip')), findsOneWidget);
      expect(GuidedTourController.instance.sessionActive, isTrue);
      final ack = (await fake.doc('users/u1/app_commands/ack').get()).data();
      expect(ack, isNotNull);
      expect(ack!['id'], 'c1');
      expect(ack['ok'], isTrue);

      // The user taps the highlighted control → a 'tapped' event for step 0.
      // The spotlight clears but the SESSION stays active (backend will send
      // the next step).
      await tester.tapAt(const Offset(56, 544));
      await settle(tester);
      final ev = (await fake.doc('users/u1/app_commands/tour_event').get()).data();
      expect(ev, isNotNull);
      expect(ev!['index'], 0);
      expect(ev['event'], 'tapped');
      expect(GuidedTourController.instance.active, isFalse);
      // The tap ALSO kicks the TEXT continuation (no live voice) so the tour
      // advances end-to-end even though no blocking advance was mid-wait —
      // the exact live failure (founder/Scout, 2026-11-03).
      expect(tourPings, [0]);
      expect(GuidedTourController.instance.sessionActive, isTrue);
    });

    testWidgets('a tour_step whose anchor is absent acks ok:false and dismisses',
        (tester) async {
      await tester.pumpWidget(controllerHost());
      final cmd = <String, dynamic>{
        'action': 'tour_step',
        'id': 'c2',
        'index': 3,
        'total': 9,
        'anchor': 'ghost_anchor_never_mounted',
        'headline': 'Nowhere',
        'say': 'This one is not here.',
      };
      await pending.set(cmd);
      svc.runTourStep(pending, cmd, id: 'c2');
      await settle(tester);

      final ack = (await fake.doc('users/u1/app_commands/ack').get()).data();
      expect(ack, isNotNull);
      expect(ack!['id'], 'c2');
      expect(ack['ok'], isFalse);
      expect(ack['reason'], 'anchor_absent');
      expect(GuidedTourController.instance.active, isFalse);
    });

    testWidgets('Skip tour writes a stop tour_event', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(controllerHost());
      final cmd = <String, dynamic>{
        'action': 'tour_step',
        'id': 'c3',
        'index': 2,
        'total': 9,
        'anchor': TourAnchors.homeOrb,
        'headline': 'Messages',
        'say': 'Tap Messages.',
      };
      await pending.set(cmd);
      svc.runTourStep(pending, cmd, id: 'c3');
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('coach-skip')));
      await settle(tester);
      final ev = (await fake.doc('users/u1/app_commands/tour_event').get()).data();
      expect(ev!['index'], 2);
      expect(ev['event'], 'stop');
      expect(GuidedTourController.instance.active, isFalse);
      expect(stopPings, [2]);
    });

    testWidgets('tapping Next on callout card writes a skip event (rewire: '
        'Next moves on WITHOUT a tap)', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(controllerHost());
      final cmd = <String, dynamic>{
        'action': 'tour_step',
        'id': 'c4',
        'index': 1,
        'total': 9,
        'anchor': TourAnchors.homeOrb,
        'headline': 'Next Step',
        'say': 'Advance via card button.',
      };
      await pending.set(cmd);
      svc.runTourStep(pending, cmd, id: 'c4');
      await settle(tester);

      // Tap Next button on callout card
      await tester.tap(find.byKey(const ValueKey('coach-next')));
      await settle(tester);
      final ev = (await fake.doc('users/u1/app_commands/tour_event').get()).data();
      expect(ev!['index'], 1);
      expect(ev['event'], 'skip');
      expect(tourPings, [1]);
    });

    testWidgets('a tour_step for another screen acks not_on_screen and '
        'shows NO highlight (rewire: look before highlighting)',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(controllerHost());
      // The user is on the Messages tab; the step lives on Explore.
      AppContext.instance.current.value =
          const ScreenContext(screen: 'messages', route: '/');
      final cmd = <String, dynamic>{
        'action': 'tour_step',
        'id': 'c5',
        'index': 1,
        'total': 19,
        'anchor': TourAnchors.exploreTab,
        'tab': 1,
        'screen': 'ayma',
        'headline': 'Explore',
        'say': 'Tap Explore.',
      };
      await pending.set(cmd);
      svc.runTourStep(pending, cmd, id: 'c5');
      // The refusal settles after a short screen-state grace period.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final ack = (await fake.doc('users/u1/app_commands/ack').get()).data();
      expect(ack, isNotNull);
      expect(ack!['id'], 'c5');
      expect(ack['ok'], isFalse);
      expect(ack['reason'], 'not_on_screen');
      expect(ack['screen'], 'messages');
      // Nothing was ever highlighted and no tour session started.
      expect(find.byKey(const ValueKey('coach-spotlight')), findsNothing);
      expect(GuidedTourController.instance.sessionActive, isFalse);
    });

    testWidgets('a tour_step on the CURRENT screen still shows and acks ok',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(controllerHost());
      AppContext.instance.current.value =
          const ScreenContext(screen: 'explore', route: '/');
      final cmd = <String, dynamic>{
        'action': 'tour_step',
        'id': 'c6',
        'index': 1,
        'total': 19,
        'anchor': TourAnchors.homeOrb,
        'tab': 1,
        'screen': 'ayma',
        'headline': 'Explore',
        'say': 'This is Explore.',
      };
      await pending.set(cmd);
      svc.runTourStep(pending, cmd, id: 'c6');
      await settle(tester);
      expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
      final ack = (await fake.doc('users/u1/app_commands/ack').get()).data();
      expect(ack!['ok'], isTrue);
      expect(ack['screen'], 'explore');
    });

    testWidgets('tour_end dismisses the overlay and acks ok', (tester) async {
      await tester.pumpWidget(controllerHost());
      GuidedTourController.instance.show(GuidedTourStep(
        token: 'x',
        feature: const TourFeature(
            featureId: 'g', headline: 'H', subtitle: 'S',
            anchorId: TourAnchors.homeOrb),
        index: 0,
        total: 1,
        onShown: () {},
        onAbsent: () {},
        onTapped: () {},
        onStop: () {},
      ));
      await settle(tester);
      expect(GuidedTourController.instance.active, isTrue);

      final ok = svc.handleCommand({'action': 'tour_end'});
      expect(ok, isTrue);
      await settle(tester);
      expect(GuidedTourController.instance.active, isFalse);
    });

    testWidgets('a second tour_step for ANOTHER screen, while a prior step is '
        'still spotlighted, acks not_on_screen (never silent) AND clears the '
        'stale spotlight (fix b/c — no zombie scrim, no un-acked step)',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(controllerHost());

      // Step 1 (the orb) shows on the current (empty-slug) screen and acks ok.
      final step1 = <String, dynamic>{
        'action': 'tour_step',
        'id': 's1',
        'index': 0,
        'total': 19,
        'anchor': TourAnchors.homeOrb,
        'headline': 'This is me',
        'say': 'This is me.',
      };
      await pending.set(step1);
      svc.runTourStep(pending, step1, id: 's1');
      await settle(tester);
      expect(GuidedTourController.instance.isShowing('s1'), isTrue);
      expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);

      // The user says "go"; the backend advances and sends step 2 — but it
      // lives on ANOTHER screen (Explore) while the user is still on Messages,
      // with step 1's spotlight still up.
      AppContext.instance.current.value =
          const ScreenContext(screen: 'messages', route: '/');
      final step2 = <String, dynamic>{
        'action': 'tour_step',
        'id': 's2',
        'index': 1,
        'total': 19,
        'anchor': TourAnchors.exploreTab,
        'tab': 1,
        'screen': 'ayma',
        'headline': 'Explore',
        'say': 'Tap Explore.',
      };
      await pending.set(step2);
      svc.runTourStep(pending, step2, id: 's2');
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // The step is acked honestly (not_on_screen) rather than left un-acked —
      // the backend gets its answer and navigates the user there.
      final ack = (await fake.doc('users/u1/app_commands/ack').get()).data();
      expect(ack, isNotNull);
      expect(ack!['id'], 's2');
      expect(ack['ok'], isFalse);
      expect(ack['reason'], 'not_on_screen');
      // The stale step-1 spotlight was cleared (no zombie scrim over the
      // screen the backend is about to navigate to), but the SESSION lives on.
      expect(GuidedTourController.instance.active, isFalse);
      expect(GuidedTourController.instance.sessionActive, isTrue);
      expect(find.byKey(const ValueKey('coach-spotlight')), findsNothing);
    });
  });

  group('page explainer through the real TourHost (founder, 2026-11-08)', () {
    late FakeFirebaseFirestore fake;
    late DocumentReference<Map<String, dynamic>> pending;
    late DocumentReference<Map<String, dynamic>> eventDoc;
    late List<int> tourPings;
    late int likes;
    late int orbTaps;
    late List<String> pushed;
    late bool voiceLive;

    AppCommandService service() => AppCommandService(
          firestore: fake,
          auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')),
          sendTourContinuation: (index) async => tourPings.add(index),
          sendTourStop: (index) async {},
          hasActiveVoice: () => voiceLive,
          chatPopupOpen: () => false,
          currentPath: () => '/profile/user/x',
          navigate: pushed.add,
        );

    // A like button on the rail and the voice orb, both real tappables.
    Widget host() {
      return MaterialApp(
        theme: AymaTheme.dark,
        builder: (context, child) => TourHost(child: child!),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                right: 16,
                top: 100,
                child: TourAnchorScope(
                  id: TourAnchors.publicProfileLike,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => likes++,
                    child: const SizedBox(width: 64, height: 64),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                bottom: 24,
                child: GestureDetector(
                  key: const ValueKey('orb'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => orbTaps++,
                  child: const SizedBox(width: 64, height: 64),
                ),
              ),
            ],
          ),
        ),
      );
    }

    Map<String, dynamic> stepCmd({Map<String, dynamic>? command}) =>
        <String, dynamic>{
          'action': 'tour_step',
          'id': 'x1',
          'index': 0,
          'total': 6,
          'anchor': TourAnchors.publicProfileLike,
          'route': '/profile/user/:uid',
          'headline': 'Like',
          'say': 'The heart is your like.',
          'command': command,
          'explainer': true,
        };

    const likeCentre = Offset(752, 132);
    const orbCentre = Offset(56, 544);

    Future<void> show(
      WidgetTester tester,
      AppCommandService svc,
      Map<String, dynamic> cmd,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      AppContext.instance.current.value = const ScreenContext(
        screen: 'profile',
        route: '/profile/user/:uid',
      );
      await tester.pumpWidget(host());
      await pending.set(cmd);
      svc.runTourStep(pending, cmd, id: cmd['id'] as String);
      await settle(tester);
    }

    setUp(() {
      GuidedTourController.instance.endSession();
      VoiceSessionController.active = null;
      fake = FakeFirebaseFirestore();
      pending = fake.doc('users/u1/app_commands/pending');
      eventDoc = fake.doc('users/u1/app_commands/tour_event');
      tourPings = <int>[];
      likes = 0;
      orbTaps = 0;
      pushed = <String>[];
      voiceLive = true;
    });

    tearDown(() {
      GuidedTourController.instance.endSession();
      AppContext.instance.current.value = const ScreenContext();
    });

    testWidgets('a tap on the highlighted like fires nothing, and on a call '
        'it is not the go', (tester) async {
      final svc = service();
      await show(tester, svc, stepCmd());
      expect(find.text('The heart is your like.'), findsOneWidget);

      await tester.tapAt(likeCentre);
      await settle(tester);

      expect(likes, 0);
      expect(pushed, isEmpty);
      expect((await eventDoc.get()).exists, isFalse);
      expect(tourPings, isEmpty);
      expect(GuidedTourController.instance.step, isNotNull);
    });

    testWidgets('a command on an explainer step is never run', (tester) async {
      final svc = service();
      await show(
        tester,
        svc,
        stepCmd(command: const {
          'action': 'navigate',
          'screen': 'story',
          'path': '/profile/wiki',
        }),
      );

      await tester.tapAt(likeCentre);
      await settle(tester);

      expect(pushed, isEmpty);
      expect(likes, 0);
      expect((await eventDoc.get()).exists, isFalse);
    });

    testWidgets('the orb never sees a tap and there is no Next on a call',
        (tester) async {
      final svc = service();
      await show(tester, svc, stepCmd());
      expect(find.text('Next'), findsNothing);

      await tester.tapAt(orbCentre);
      await settle(tester);

      expect(orbTaps, 0);
      expect(GuidedTourController.instance.step, isNotNull);
    });

    testWidgets('if the call drops, a tap completes the step and still fires '
        'nothing', (tester) async {
      voiceLive = false;
      final svc = service();
      await show(tester, svc, stepCmd());

      await tester.tapAt(likeCentre);
      await settle(tester);

      expect(likes, 0);
      expect(pushed, isEmpty);
      expect((await eventDoc.get()).data()?['event'], 'tapped');
      expect(tourPings, [0]);
    });
  });

  group('TourAnchorScope', () {
    testWidgets('two mounted copies do not collide and the newest resolves',
        (tester) async {
      Widget box(double top) => Positioned(
            top: top,
            left: 0,
            child: TourAnchorScope(
              id: TourAnchors.publicProfileLike,
              child: const SizedBox(width: 10, height: 10),
            ),
          );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(children: [box(0), box(50)]),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(TourAnchors.rectFor(TourAnchors.publicProfileLike)?.top, 50);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(children: [box(0)]),
        ),
      );
      expect(TourAnchors.rectFor(TourAnchors.publicProfileLike)?.top, 0);

      await tester.pumpWidget(const SizedBox());
      expect(TourAnchors.rectFor(TourAnchors.publicProfileLike), isNull);
    });
  });

  group('action-driven steps through the real TourHost (founder, 2026-11-08)', () {
    late FakeFirebaseFirestore fake;
    late DocumentReference<Map<String, dynamic>> pending;
    late DocumentReference<Map<String, dynamic>> eventDoc;
    late List<int> tourPings;
    late int realTaps;
    late int pageTaps;
    late ScrollController pageScroll;
    late bool voiceLive;
    late String routerPath;
    late List<String> pushed;

    AppCommandService service() => AppCommandService(
          firestore: fake,
          auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')),
          sendTourContinuation: (index) async => tourPings.add(index),
          sendTourStop: (index) async {},
          hasActiveVoice: () => voiceLive,
          chatPopupOpen: () => false,
          currentPath: () => routerPath,
          navigate: (path) {
            pushed.add(path);
            routerPath = path;
          },
        );

    // The real TourHost over a real tappable control at the anchor, plus a
    // stand-in for the shell's tab switch (TabRequest -> AppContext slug).
    Widget host() {
      return MaterialApp(
        theme: AymaTheme.dark,
        builder: (context, child) => TourHost(child: child!),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 24,
                bottom: 24,
                child: VoiceControlMark(
                  child: GestureDetector(
                    key: TourAnchors.keyFor(TourAnchors.homeOrb),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => realTaps++,
                    child: const SizedBox(width: 64, height: 64),
                  ),
                ),
              ),
              Positioned(
                left: 200,
                top: 0,
                width: 200,
                height: 300,
                child: ListView(
                  key: const ValueKey('opened-page-list'),
                  controller: pageScroll,
                  children: [
                    GestureDetector(
                      key: const ValueKey('opened-page-button'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => pageTaps++,
                      child: const SizedBox(height: 60),
                    ),
                    const SizedBox(height: 2000),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    void Function() shellStub() {
      const slugs = ['ayma', 'explore', 'messages', 'profile_tab'];
      void listener() {
        final tab = TabRequest.instance.consume();
        if (tab != null) {
          AppContext.instance.current.value =
              ScreenContext(screen: slugs[tab], route: '/');
        }
      }

      TabRequest.instance.pending.addListener(listener);
      return () => TabRequest.instance.pending.removeListener(listener);
    }

    Map<String, dynamic> stepCmd(String id, {Map<String, dynamic>? command}) =>
        <String, dynamic>{
          'action': 'tour_step',
          'id': id,
          'index': 1,
          'total': 9,
          'anchor': TourAnchors.homeOrb,
          'headline': 'Explore',
          'say': 'Tap Explore.',
          'command': command,
        };

    const tabCommand = <String, dynamic>{'action': 'switch_tab', 'tab': 1};
    const navCommand = <String, dynamic>{
      'action': 'navigate',
      'screen': 'story',
      'path': '/profile/wiki',
    };
    const anchorTap = Offset(56, 544);

    Future<void> show(
      WidgetTester tester,
      AppCommandService svc,
      Map<String, dynamic> cmd,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host());
      await pending.set(cmd);
      svc.runTourStep(pending, cmd, id: cmd['id'] as String);
      await settle(tester);
    }

    Future<Map<String, dynamic>?> lastEvent() async =>
        (await eventDoc.get()).data();

    setUp(() {
      GuidedTourController.instance.endSession();
      AppContext.instance.current.value = const ScreenContext();
      VoiceSessionController.active = null;
      TabRequest.instance.consume();
      fake = FakeFirebaseFirestore();
      pending = fake.doc('users/u1/app_commands/pending');
      eventDoc = fake.doc('users/u1/app_commands/tour_event');
      tourPings = <int>[];
      realTaps = 0;
      pageTaps = 0;
      pageScroll = ScrollController();
      voiceLive = false;
      routerPath = '/';
      pushed = <String>[];
    });

    tearDown(() => GuidedTourController.instance.endSession());

    testWidgets('Ayma switches the tab on presentation — no tap at all — '
        'and the tour waits for the go', (tester) async {
      addTearDown(shellStub());
      final svc = service();
      await show(tester, svc, stepCmd('a1', command: tabCommand));

      // ZERO taps: the step performed itself the moment it was shown
      // (founder, 2026-11-09 — Ayma handles the tap, the user never taps).
      await settle(tester);

      expect(realTaps, 0);
      expect(AppContext.instance.current.value.screen, 'explore');
      final ev = await lastEvent();
      expect(ev!['event'], 'performed');
      expect(ev['index'], 1);
      expect(ev['attempt'], 1);
      // Still on this step, highlight gone; no timed advance. Driven mode is
      // chromeless (Item B): NO callout card — Ayma invites the go in her own
      // line, so there is no on-screen "N of M", "tap Next" or Skip tour.
      final guided = GuidedTourController.instance;
      expect(guided.active, isTrue);
      expect(guided.step!.performed, isTrue);
      expect(find.byKey(const ValueKey('coach-next')), findsNothing);
      expect(find.byKey(const ValueKey('coach-skip')), findsNothing);
      expect(find.textContaining('tap Next'), findsNothing);
      expect(find.text('2 of 9'), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(guided.active, isTrue);
      expect((await lastEvent())!['event'], 'performed');
      // Text surface: no model turn is spent on a performed step.
      expect(tourPings, isEmpty);
    });

    testWidgets('a performed driven step shows NO card — the go is Ayma\'s '
        'line, not a button (Item B)', (tester) async {
      addTearDown(shellStub());
      final svc = service();
      await show(tester, svc, stepCmd('a2', command: tabCommand));
      await tester.tapAt(anchorTap);
      await settle(tester);

      // The action ran and the step rests, but there is no callout card at
      // all: no Next, no Skip tour, no step counter. The user advances by
      // telling Ayma "next" (she calls skip_guided_tour) — no phone 'skip'
      // event is produced from a button any more.
      expect((await lastEvent())!['event'], 'performed');
      expect(find.byKey(const ValueKey('coach-next')), findsNothing);
      expect(find.byKey(const ValueKey('coach-skip')), findsNothing);
      final guided = GuidedTourController.instance;
      expect(guided.active, isTrue);
      expect(guided.step!.performed, isTrue);
    });

    testWidgets('a tap on the spot after it is performed does not run it again',
        (tester) async {
      final svc = service();
      await show(tester, svc, stepCmd('a3', command: navCommand));

      await tester.tapAt(anchorTap);
      await settle(tester);
      await tester.tapAt(anchorTap);
      await settle(tester);

      expect(pushed, ['/profile/wiki']);
      expect((await lastEvent())!['attempt'], 1);
      expect((await lastEvent())!['event'], 'performed');
    });

    testWidgets('the opened page scrolls and works while the tour waits, and '
        'a tap on it is not the go', (tester) async {
      addTearDown(shellStub());
      final svc = service();
      await show(tester, svc, stepCmd('a3b', command: tabCommand));
      await tester.tapAt(anchorTap);
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('opened-page-button')));
      await settle(tester);
      await tester.drag(
        find.byKey(const ValueKey('opened-page-list')),
        const Offset(0, -200),
      );
      await settle(tester);

      expect(pageTaps, 1);
      expect(pageScroll.offset, greaterThan(0));
      final guided = GuidedTourController.instance;
      expect(guided.active, isTrue);
      expect(guided.step!.performed, isTrue);
      expect((await lastEvent())!['event'], 'performed');
      expect(tourPings, isEmpty);
    });

    testWidgets('the step performs on presentation with no tap — there is '
        'no blocked waiting-for-a-tap state any more', (tester) async {
      final svc = service();
      await show(tester, svc, stepCmd('a3c', command: navCommand));
      await settle(tester);

      // No tap was needed and none happened: Ayma navigated herself.
      expect(pushed, ['/profile/wiki']);
      expect(GuidedTourController.instance.step!.performed, isTrue);
      expect((await lastEvent())!['event'], 'performed');
    });

    testWidgets('on a call a performed step blocks the orb but not the page',
        (tester) async {
      addTearDown(shellStub());
      voiceLive = true;
      final svc = service();
      await show(tester, svc, stepCmd('a3d', command: tabCommand));
      await tester.tapAt(anchorTap);
      await settle(tester);
      expect(GuidedTourController.instance.step!.performed, isTrue);
      expect(find.byKey(const ValueKey('coach-next')), findsNothing);

      await tester.tapAt(anchorTap);
      await settle(tester);
      expect(realTaps, 0);
      expect((await lastEvent())!['event'], 'performed');

      await tester.tap(find.byKey(const ValueKey('opened-page-button')));
      await settle(tester);
      expect(pageTaps, 1);
    });

    testWidgets('with no call the orb is live again on a performed step',
        (tester) async {
      addTearDown(shellStub());
      final svc = service();
      await show(tester, svc, stepCmd('a3e', command: tabCommand));
      await settle(tester);
      // The step performed itself on presentation; the orb underneath is
      // the user's again, so the first tap after that reaches it.
      expect(GuidedTourController.instance.step!.performed, isTrue);

      await tester.tapAt(anchorTap);
      await settle(tester);

      expect(realTaps, 1);
      expect((await lastEvent())!['event'], 'performed');
    });

    testWidgets('a double tap performs the step once', (tester) async {
      addTearDown(shellStub());
      final svc = service();
      await show(tester, svc, stepCmd('a4', command: navCommand));

      GuidedTourController.instance.step!.onTapped();
      GuidedTourController.instance.step!.onTapped();
      await settle(tester);

      expect(pushed, ['/profile/wiki']);
      expect((await lastEvent())!['attempt'], 1);
    });

    testWidgets('a failed action stays on the step, says so, and can be '
        'retried', (tester) async {
      final svc = service();
      // No shell is listening, so the tab switch can't be confirmed.
      await show(tester, svc, stepCmd('a5', command: tabCommand));

      await tester.tapAt(anchorTap);
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);

      expect((await lastEvent())!['event'], 'action_failed');
      final guided = GuidedTourController.instance;
      expect(guided.active, isTrue);
      expect(guided.step!.performed, isFalse);
      // Driven mode is chromeless: no card, so the "didn't open" line is
      // Ayma's spoken/typed line, not an on-screen card. The highlight stays
      // up (not performed) so the user can tap to retry.
      expect(find.byKey(const ValueKey('coach-next')), findsNothing);
      expect(TabRequest.instance.pending.value, isNull);

      addTearDown(shellStub());
      await tester.tapAt(anchorTap);
      await settle(tester);
      final ev = await lastEvent();
      expect(ev!['event'], 'performed');
      expect(ev['attempt'], 2);
    });

    testWidgets('a look step completes on the tap in text, without reaching '
        'the real control', (tester) async {
      final svc = service();
      await show(tester, svc, stepCmd('a6'));

      await tester.tapAt(anchorTap);
      await settle(tester);

      expect(realTaps, 0);
      expect((await lastEvent())!['event'], 'tapped');
      expect(tourPings, [1]);
    });

    testWidgets('on a call the orb (no-command) step rests on the SPOKEN go: it '
        'auto-reports performed on show and never needs an orb tap (fix a)',
        (tester) async {
      voiceLive = true;
      final svc = service();
      await show(tester, svc, stepCmd('a7'));

      // Fix (a): the orb IS the call bar on a live call, so the step cannot
      // wait on a tap — the instant it is shown it reports 'performed', so
      // advance_guided_tour returns at once (no ~110s tap-window hang) and the
      // tour rests on the user's spoken "go" (skip_guided_tour). Chromeless:
      // no card, no Skip tour.
      final ev = await lastEvent();
      expect(ev!['event'], 'performed');
      expect(ev['index'], 1);
      expect(ev['attempt'], 1);
      final guided = GuidedTourController.instance;
      expect(guided.active, isTrue);
      expect(guided.step!.performed, isTrue);
      expect(find.byKey(const ValueKey('coach-next')), findsNothing);
      expect(find.byKey(const ValueKey('coach-skip')), findsNothing);
      // The agent is told so she can invite the spoken go.
      expect(tourPings, [1]);

      // A tap on the orb is neither the go nor a real orb tap — it is swallowed
      // (the call never disconnects) and nothing new happens.
      await tester.tapAt(anchorTap);
      await settle(tester);
      expect(realTaps, 0);
      expect((await lastEvent())!['event'], 'performed');
      expect(guided.active, isTrue);
    });

    testWidgets('on a call the highlight still performs the step and the agent '
        'is told; the go stays spoken', (tester) async {
      addTearDown(shellStub());
      voiceLive = true;
      final svc = service();
      await show(tester, svc, stepCmd('a8', command: tabCommand));

      // Zero taps on a call too: performed on presentation, agent told once.
      await settle(tester);

      expect((await lastEvent())!['event'], 'performed');
      expect(tourPings, [1]);
      // Chromeless: the "say next" invitation is Ayma's spoken line, not a card.
      expect(find.byKey(const ValueKey('coach-next')), findsNothing);
      expect(find.textContaining('say next'), findsNothing);
    });

    testWidgets('driven mode shows no card whether a call is live or it drops '
        '(Item B): advancing is always Ayma\'s line, never a card button',
        (tester) async {
      voiceLive = true;
      final svc = service();
      // A command step so the orb-step auto-perform (fix a) isn't in play here.
      addTearDown(shellStub());
      await show(tester, svc, stepCmd('a9', command: tabCommand));
      await tester.tapAt(anchorTap);
      await settle(tester);
      expect(find.byKey(const ValueKey('coach-next')), findsNothing);

      // The call drops mid-step — still no card (self-guided would show one;
      // driven never does).
      GuidedTourController.instance.setVoiceOnly(false);
      await settle(tester);
      expect(find.byKey(const ValueKey('coach-next')), findsNothing);
      expect(find.byKey(const ValueKey('coach-skip')), findsNothing);
    });

    test('a navigate that never leaves the page reports false, not the '
        'dispatch', () async {
      final svc = AppCommandService(
        firestore: fake,
        auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')),
        chatPopupOpen: () => false,
        currentPath: () => '/',
        navigate: (_) {},
      );
      expect(await svc.runTourCommand(navCommand), isFalse);
    });

    test('a navigate that redirects elsewhere still counts as landed',
        () async {
      var path = '/';
      final svc = AppCommandService(
        firestore: fake,
        auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')),
        chatPopupOpen: () => false,
        currentPath: () => path,
        navigate: (_) => path = '/skills',
      );
      expect(await svc.runTourCommand(navCommand), isTrue);
    });

    test('an unusable command reports false', () async {
      final svc = service();
      expect(await svc.runTourCommand({'action': 'nonsense'}), isFalse);
      expect(
        await svc.runTourCommand({'action': 'switch_tab', 'tab': 9}),
        isFalse,
      );
    });
  });

  group('driven vs self-guided card (Item B, founder 2026-11-08)', () {
    Widget hostWith(Widget overlayOwnerChild) => MaterialApp(
          theme: AymaTheme.dark,
          builder: (context, child) => TourHost(child: child!),
          home: Scaffold(
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
                overlayOwnerChild,
              ],
            ),
          ),
        );

    setUp(() {
      GuidedTourController.instance.endSession();
      TourController.instance.finish();
    });
    tearDown(() {
      GuidedTourController.instance.endSession();
      TourController.instance.finish();
    });

    testWidgets('a DRIVEN (non-explainer) step renders chromeless — no card, '
        'no counter, no Skip tour', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(hostWith(const SizedBox.shrink()));
      GuidedTourController.instance.show(GuidedTourStep(
        token: 'd1',
        feature: const TourFeature(
            featureId: 'g', headline: 'This is me', subtitle: 'This is me.',
            anchorId: TourAnchors.homeOrb),
        index: 0,
        total: 19,
        onShown: () {},
        onAbsent: () {},
        onTapped: () {},
        onStop: () {},
        // explainer: false (default) → a real driven-tour step.
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
      expect(find.text('This is me'), findsNothing); // no headline card
      expect(find.text('1 of 19'), findsNothing); // no counter
      expect(find.byKey(const ValueKey('coach-next')), findsNothing);
      expect(find.byKey(const ValueKey('coach-skip')), findsNothing); // no Skip
    });

    testWidgets('a page-explainer step keeps its card (stays as built)',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(hostWith(const SizedBox.shrink()));
      GuidedTourController.instance.show(GuidedTourStep(
        token: 'e1',
        feature: const TourFeature(
            featureId: 'g', headline: 'The heart', subtitle: 'This is the like.',
            anchorId: TourAnchors.homeOrb),
        index: 0,
        total: 6,
        onShown: () {},
        onAbsent: () {},
        onTapped: () {},
        onStop: () {},
        explainer: true,
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
      expect(find.text('The heart'), findsOneWidget); // card headline
      expect(find.text('This is the like.'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-skip')), findsOneWidget);
    });

    testWidgets('a SELF-GUIDED (passive) tour still shows its full card',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(hostWith(const SizedBox.shrink()));
      TourController.instance.start(
        const [
          TourFeature(
            featureId: 'passive_1',
            headline: 'Your orb',
            subtitle: 'Press and hold the orb to talk.',
            anchorId: TourAnchors.homeOrb,
          ),
        ],
        spotlight: false,
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      // Self-guided mode is UNCHANGED: the full callout card still renders.
      expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
      expect(find.text('Your orb'), findsOneWidget);
      expect(find.text('Press and hold the orb to talk.'), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-next')), findsOneWidget);
      expect(find.byKey(const ValueKey('coach-skip')), findsOneWidget);
    });
  });

  group('state-based completion + teardown guarantee (founder, 2026-11-09)',
      () {
    late FakeFirebaseFirestore fake;
    late DocumentReference<Map<String, dynamic>> pending;
    late DocumentReference<Map<String, dynamic>> eventDoc;
    late DocumentReference<Map<String, dynamic>> stateDoc;
    late List<int> tourPings;
    late List<int> stopPings;
    late int realTaps;
    late bool voiceLive;
    late String routerPath;
    late List<String> pushed;

    AppCommandService service() => AppCommandService(
          firestore: fake,
          auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')),
          sendTourContinuation: (index) async => tourPings.add(index),
          sendTourStop: (index) async => stopPings.add(index),
          hasActiveVoice: () => voiceLive,
          chatPopupOpen: () => false,
          currentPath: () => routerPath,
          navigate: (path) {
            pushed.add(path);
            routerPath = path;
          },
        );

    // The real TourHost over a real tappable orb anchor: the tour's own
    // machinery end to end, with only the router path and the tab shell
    // stubbed (the same shape as the action-driven group above).
    Widget host() {
      return MaterialApp(
        theme: AymaTheme.dark,
        builder: (context, child) => TourHost(child: child!),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 24,
                bottom: 24,
                child: VoiceControlMark(
                  child: GestureDetector(
                    key: TourAnchors.keyFor(TourAnchors.homeOrb),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => realTaps++,
                    child: const SizedBox(width: 64, height: 64),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    void Function() shellStub() {
      const slugs = ['ayma', 'explore', 'messages', 'profile_tab'];
      void listener() {
        final tab = TabRequest.instance.consume();
        if (tab != null) {
          AppContext.instance.current.value =
              ScreenContext(screen: slugs[tab], route: '/');
        }
      }

      TabRequest.instance.pending.addListener(listener);
      return () => TabRequest.instance.pending.removeListener(listener);
    }

    Map<String, dynamic> stepCmd(
      String id, {
      Map<String, dynamic>? command,
      bool explainer = false,
      int index = 1,
      int total = 9,
      String? route,
      String say = 'Tap Explore.',
    }) =>
        <String, dynamic>{
          'action': 'tour_step',
          'id': id,
          'index': index,
          'total': total,
          'anchor': TourAnchors.homeOrb,
          'headline': 'Explore',
          'say': say,
          'command': command,
          'explainer': explainer,
          if (route != null) 'route': route,
        };

    // The founder's bell: Ayma performs a navigate to Notifications.
    const bellCommand = <String, dynamic>{
      'action': 'navigate',
      'screen': 'notifications',
      'path': '/notifications',
    };
    const tabCommand = <String, dynamic>{'action': 'switch_tab', 'tab': 1};
    const storyCommand = <String, dynamic>{
      'action': 'navigate',
      'screen': 'story',
      'path': '/profile/wiki',
    };

    Future<void> show(
      WidgetTester tester,
      AppCommandService svc,
      Map<String, dynamic> cmd,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host());
      await pending.set(cmd);
      svc.runTourStep(pending, cmd, id: cmd['id'] as String);
      await settle(tester);
    }

    Future<void> pumpSeconds(WidgetTester tester, double seconds) async {
      final steps = (seconds * 10).round();
      for (var i = 0; i < steps; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    setUp(() {
      GuidedTourController.instance.endSession();
      AppContext.instance.current.value = const ScreenContext();
      VoiceSessionController.active = null;
      TabRequest.instance.consume();
      fake = FakeFirebaseFirestore();
      pending = fake.doc('users/u1/app_commands/pending');
      eventDoc = fake.doc('users/u1/app_commands/tour_event');
      stateDoc = fake.doc('users/u1/app_commands/tour_state');
      tourPings = <int>[];
      stopPings = <int>[];
      realTaps = 0;
      voiceLive = false;
      routerPath = '/';
      pushed = <String>[];
    });

    tearDown(() {
      GuidedTourController.instance.endSession();
      AppContext.instance.current.value = const ScreenContext();
    });

    testWidgets('the bell step performs ITSELF on presentation — Ayma opens '
        'Notifications, no user tap (the founder failure, 2026-11-09)',
        (tester) async {
      final svc = service();
      await show(tester, svc, stepCmd('b1', command: bellCommand));
      await pumpSeconds(tester, 1.2);

      // The tour waited for a user tap before; now the step runs its own
      // command the moment it is shown and reports the outcome itself.
      final ev = (await eventDoc.get()).data();
      expect(ev, isNotNull);
      expect(ev!['event'], 'performed');
      expect(ev['index'], 1);
      expect(ev['attempt'], 1);
      expect(pushed, ['/notifications']); // Ayma navigated herself
      expect(realTaps, 0); // and never needed a tap on the highlight
      expect(GuidedTourController.instance.step!.performed, isTrue);
    });

    testWidgets('when Ayma\'s own attempt cannot confirm, the step still '
        'completes from the state when the user gets there themselves',
        (tester) async {
      final svc = service();
      // No shell is listening, so Ayma's own tab switch cannot confirm.
      await show(tester, svc, stepCmd('b2', command: tabCommand));
      await pumpSeconds(tester, 3);

      var ev = (await eventDoc.get()).data();
      expect(ev, isNotNull);
      expect(ev!['event'], 'action_failed');
      expect(ev['attempt'], 1);
      expect(GuidedTourController.instance.step!.performed, isFalse);

      // The user taps the real Explore tab; the shell applies it, exactly
      // as it applies Ayma's own TabRequest — and the state watch completes
      // the step through the same outcome path (founder: however they got
      // there, the step must notice).
      addTearDown(shellStub());
      TabRequest.instance.request(1);
      await pumpSeconds(tester, 1.2);

      expect(AppContext.instance.current.value.screen, 'explore');
      ev = (await eventDoc.get()).data();
      expect(ev, isNotNull);
      expect(ev!['event'], 'performed');
      expect(ev['attempt'], 2);
      expect(realTaps, 0);
      expect(GuidedTourController.instance.step!.performed, isTrue);
    });

    testWidgets('a step whose goal is ALREADY true when it arrives completes '
        'at once (no tap, no wait)', (tester) async {
      routerPath = '/profile/wiki'; // the user is already on the page
      final svc = service();
      await show(tester, svc, stepCmd('b3', command: storyCommand));
      await pumpSeconds(tester, 0.6);

      final ev = (await eventDoc.get()).data();
      expect(ev, isNotNull);
      expect(ev!['event'], 'performed');
      expect(pushed, isEmpty);
      expect(GuidedTourController.instance.step!.performed, isTrue);
    });

    testWidgets('teardown: tour_state going inactive ends the session and '
        'takes the step down (a lost tour_end can no longer strand it)',
        (tester) async {
      final svc = service();
      await show(tester, svc, stepCmd('b4'));
      expect(GuidedTourController.instance.sessionActive, isTrue);

      // The tour ended server-side; its tour_end never reached this client.
      await stateDoc.set(<String, dynamic>{
        'active': false,
        'index': -1,
        'updated_at': Timestamp.now(),
      });
      await svc.checkTourState();
      await settle(tester);

      expect(GuidedTourController.instance.sessionActive, isFalse);
      expect(GuidedTourController.instance.active, isFalse);
    });

    testWidgets('teardown: a tour_state stale past the backend TTL ends the '
        'session on its own', (tester) async {
      final svc = service();
      await show(tester, svc, stepCmd('b5'));
      expect(GuidedTourController.instance.sessionActive, isTrue);

      await stateDoc.set(<String, dynamic>{
        'active': true,
        'index': 1,
        'updated_at': Timestamp.fromDate(
          DateTime.now().subtract(const Duration(minutes: 20)),
        ),
      });
      await svc.checkTourState();
      await settle(tester);

      expect(GuidedTourController.instance.sessionActive, isFalse);
      expect(GuidedTourController.instance.active, isFalse);
    });

    testWidgets('teardown: a live, fresh tour_state leaves the session '
        'exactly as it is', (tester) async {
      final svc = service();
      await show(tester, svc, stepCmd('b6'));
      expect(GuidedTourController.instance.sessionActive, isTrue);

      await stateDoc.set(<String, dynamic>{
        'active': true,
        'index': 1,
        'updated_at': Timestamp.now(),
      });
      await svc.checkTourState();
      await settle(tester);

      expect(GuidedTourController.instance.sessionActive, isTrue);
      expect(GuidedTourController.instance.active, isTrue);
    });

    testWidgets('the final explainer card is removed when the tour ends '
        'server-side (founder: "the card is not removed", 2026-11-09)',
        (tester) async {
      final svc = service();
      await show(
        tester,
        svc,
        stepCmd(
          'b7',
          explainer: true,
          index: 6,
          total: 7,
          say: 'This shows your plan, your credits and what they have '
              'been spent on.',
        ),
      );
      // The last step's card is up over the You page.
      expect(
        find.text('This shows your plan, your credits and what they have '
            'been spent on.'),
        findsOneWidget,
      );
      expect(find.text('7 of 7'), findsOneWidget);

      // The explainer completes server-side but the tour_end is lost.
      await stateDoc.set(<String, dynamic>{
        'active': false,
        'index': -1,
        'updated_at': Timestamp.now(),
      });
      await svc.checkTourState();
      await settle(tester);

      expect(GuidedTourController.instance.sessionActive, isFalse);
      expect(
        find.text('This shows your plan, your credits and what they have '
            'been spent on.'),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('coach-spotlight')), findsNothing);
    });

    testWidgets('an explainer ends when the user leaves its page — the card '
        'does not follow them', (tester) async {
      final svc = service();
      AppContext.instance.current.value = const ScreenContext(
        screen: 'profile',
        route: '/profile/user/:uid',
      );
      await show(
        tester,
        svc,
        stepCmd(
          'b8',
          explainer: true,
          index: 0,
          total: 6,
          route: '/profile/user/:uid',
          say: 'The heart is your like.',
        ),
      );
      expect(GuidedTourController.instance.active, isTrue);

      // The user leaves the explained page entirely, and lands somewhere
      // else — two off-page publications in a row.
      AppContext.instance.current.value =
          const ScreenContext(screen: 'ayma', route: '/');
      await tester.pump(const Duration(milliseconds: 100));
      AppContext.instance.current.value =
          const ScreenContext(screen: 'explore', route: '/');
      await tester.pump(const Duration(milliseconds: 100));

      final ev = (await eventDoc.get()).data();
      expect(ev, isNotNull);
      expect(ev!['event'], 'stop');
      expect(GuidedTourController.instance.sessionActive, isFalse);
      expect(stopPings, [0]);
    });
  });

  group('passive tour teardown (founder, 2026-11-09)', () {
    tearDown(() {
      TourController.instance.finish();
    });

    Widget host() {
      return MaterialApp(
        theme: AymaTheme.dark,
        builder: (context, child) => TourHost(child: child!),
        home: const Scaffold(body: SizedBox.expand()),
      );
    }

    const steps = <TourFeature>[
      TourFeature(featureId: 'pt_first', headline: 'First', subtitle: 'One.'),
      TourFeature(
          featureId: 'pt_last', headline: 'Your plan', subtitle: 'Two.'),
    ];

    testWidgets('finishing the last step removes the card and closes the '
        'tour', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host());
      TourController.instance.start(steps, spotlight: false);
      await settle(tester);
      expect(find.text('First'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('coach-next')));
      await settle(tester);
      expect(find.text('Your plan'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('coach-next')));
      await settle(tester);
      expect(TourController.instance.active, isFalse);
      expect(find.text('Your plan'), findsNothing);
      expect(find.byKey(const ValueKey('coach-spotlight')), findsNothing);
    });

    testWidgets('Skip tour on the last step removes the card and closes '
        'the tour', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host());
      TourController.instance.start(steps, spotlight: false);
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('coach-next')));
      await settle(tester);
      expect(find.text('Your plan'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('coach-skip')));
      await settle(tester);
      expect(TourController.instance.active, isFalse);
      expect(find.text('Your plan'), findsNothing);
      expect(find.byKey(const ValueKey('coach-spotlight')), findsNothing);
    });
  });

}
