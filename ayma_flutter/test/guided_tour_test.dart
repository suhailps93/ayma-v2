import 'package:ayma_flutter/services/app_command_service.dart';
import 'package:ayma_flutter/services/guided_tour_controller.dart';
import 'package:ayma_flutter/services/tour_anchors.dart';
import 'package:ayma_flutter/services/tour_content.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/coach_mark_overlay.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Ayma-DRIVEN interactive tour (§11.2b): the backend pushes one step at a
/// time; the client spotlights it with the shared [CoachMarkOverlay] in driven
/// mode and reports shown / absent / tapped / stop back, so the agent advances
/// only after the user taps the real control.
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
                        chromeless: true,
                        maxMeasureAttempts: 3,
                        onFinish: GuidedTourController.instance.endSession,
                        onAnchorShown: step.onShown,
                        onAnchorAbsent: step.onAbsent,
                        onAnchorTapped: step.onTapped,
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

    setUp(() async {
      GuidedTourController.instance.endSession();
      fake = FakeFirebaseFirestore();
      svc = AppCommandService(
        firestore: fake,
        auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')),
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

      // The spotlight is up (chromeless — no card text) and the step was acked
      // as shown. The session is active.
      expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
      expect(find.text('Explore'), findsNothing);
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
  });
}
