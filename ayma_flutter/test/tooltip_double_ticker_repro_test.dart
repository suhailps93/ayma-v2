import 'package:ayma_flutter/screens/voice_call_screen.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:ayma_flutter/widgets/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [VoiceSessionController] fake for driving [VoiceCallScreen] and voice-mode
/// composer widgets deterministically in widget tests without hitting network.
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  VoiceSessionPhase _fakePhase = VoiceSessionPhase.idle;
  bool _fakeSpeaking = false;
  bool _fakeMuted = false;
  bool _fakeQuiet = false;
  int toggleMuteCalls = 0;
  int unmuteAymaCalls = 0;

  @override
  VoiceSessionPhase get phase => _fakePhase;

  @override
  bool get agentSpeaking => _fakeSpeaking;

  @override
  bool get muted => _fakeMuted;

  @override
  bool get aymaQuiet => _fakeQuiet;

  @override
  Future<void> unmuteAyma() async {
    unmuteAymaCalls += 1;
    _fakeQuiet = false;
    notifyListeners();
  }

  void setQuiet(bool quiet) {
    _fakeQuiet = quiet;
    notifyListeners();
  }

  @override
  bool get isActive =>
      _fakePhase == VoiceSessionPhase.connecting ||
      _fakePhase == VoiceSessionPhase.waking ||
      _fakePhase == VoiceSessionPhase.live;

  @override
  bool get isListening => _fakePhase == VoiceSessionPhase.live;

  bool _fakeResponded = false;

  @override
  bool get awaitingFirstResponse =>
      _fakePhase == VoiceSessionPhase.live && !_fakeResponded;

  void setResponded() {
    _fakeResponded = true;
    notifyListeners();
  }

  void setPhase(VoiceSessionPhase phase) {
    _fakePhase = phase;
    notifyListeners();
  }

  void setSpeaking(bool speaking) {
    _fakeSpeaking = speaking;
    notifyListeners();
  }

  @override
  Future<void> toggleMute() async {
    toggleMuteCalls += 1;
    _fakeMuted = !_fakeMuted;
    notifyListeners();
  }

  @override
  Future<void> start({bool forceRelayFirst = false}) async {
    setPhase(VoiceSessionPhase.connecting);
    await Future<void>.delayed(Duration.zero);
    setPhase(VoiceSessionPhase.live);
  }

  @override
  Future<void> stop() async {
    setPhase(VoiceSessionPhase.idle);
  }
}

/// Helper to build [ChatComposer] with all required parameters defaulted.
Widget testComposer({
  required TextEditingController controller,
  required FocusNode focusNode,
  ComposerMode mode = ComposerMode.text,
  bool canSend = false,
  bool muted = false,
  VoidCallback? onSend,
  VoidCallback? onAttach,
  VoidCallback? onMicPressed,
  VoidCallback? onStopPressed,
  VoidCallback? onMuteTap,
  VoidCallback? onExpandTap,
  String? statusLabel,
}) {
  return ChatComposer(
    mode: mode,
    controller: controller,
    focusNode: focusNode,
    canSend: canSend,
    onSend: onSend ?? () {},
    onAttach: onAttach ?? () {},
    onMicPressed: onMicPressed ?? () {},
    onStopPressed: onStopPressed ?? () {},
    onMuteTap: onMuteTap ?? () {},
    onExpandTap: onExpandTap,
    muted: muted,
    userAmplitude: const AlwaysStoppedAnimation(0.0),
    aiAmplitude: const AlwaysStoppedAnimation(0.0),
    statusLabel: statusLabel,
  );
}

/// Reproduction attempts for AYMA-FLUTTER-3S:
/// "RawTooltipState is a SingleTickerProviderStateMixin but multiple
/// tickers were created" — 2 events, Nov 6 2026 21:40 PT, founder Pixel,
/// build 2327, inside the FLUTTER-3R semantics-storm window. The Sentry
/// stack is a pointer-down event reaching RawTooltipState's global
/// pointer handler, which lazily creates the tooltip's animation
/// controller — and the framework refuses because a ticker already
/// exists on that state. Each scenario drives one plausible sequence
/// and fails if that sequence throws the double-ticker error.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget app({required Widget child, Key? key, ThemeData? theme}) {
    return MaterialApp(
      theme: theme ?? AymaTheme.dark,
      home: Scaffold(body: Center(child: child)),
    );
  }

  dynamic takeError(WidgetTester tester) => tester.takeException();

  group('Original 7 baseline repro scenarios', () {
    testWidgets('show then dismiss then tap elsewhere', (tester) async {
      await tester.pumpWidget(app(
        child: const Tooltip(message: 'Mute', child: Icon(Icons.mic)),
      ));
      await tester.longPress(find.byType(Tooltip));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
      // Tap elsewhere to dismiss, then tap again.
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
    });

    testWidgets('show then rebuild with new message while showing',
        (tester) async {
      var message = 'Mute';
      await tester.pumpWidget(app(
        child: StatefulBuilder(
          builder: (context, setState) => Tooltip(
            message: message,
            child: TextButton(
              onPressed: () => setState(() => message = 'Unmute'),
              child: const Text('tap'),
            ),
          ),
        ),
      ));
      await tester.longPress(find.byType(Tooltip));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
      await tester.tap(find.text('tap'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
    });

    testWidgets('show then remove from tree while showing, then tap',
        (tester) async {
      var showTooltip = true;
      await tester.pumpWidget(app(
        child: StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              if (showTooltip)
                const Tooltip(message: 'One', child: Icon(Icons.star)),
              const Tooltip(message: 'Two', child: Icon(Icons.favorite)),
              TextButton(
                onPressed: () => setState(() => showTooltip = false),
                child: const Text('remove'),
              ),
            ],
          ),
        ),
      ));
      await tester.longPress(find.byIcon(Icons.star));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
      await tester.tap(find.text('remove'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
    });

    testWidgets('manual trigger tooltip tapped repeatedly (tab-bar pattern)',
        (tester) async {
      await tester.pumpWidget(app(
        child: const Tooltip(
          message: 'Hold 1s for voice',
          triggerMode: TooltipTriggerMode.manual,
          child: Icon(Icons.mic),
        ),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byIcon(Icons.mic));
        await tester.pump(const Duration(milliseconds: 100));
        expect(takeError(tester), isNull);
      }
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 200));
      expect(takeError(tester), isNull);
    });

    testWidgets('two tooltips: show first, tap second child', (tester) async {
      await tester.pumpWidget(app(
        child: const Row(
          children: [
            Tooltip(message: 'One', child: Icon(Icons.star)),
            Tooltip(message: 'Two', child: Icon(Icons.favorite)),
          ],
        ),
      ));
      await tester.longPress(find.byIcon(Icons.star));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
      await tester.tap(find.byIcon(Icons.favorite));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
    });

    testWidgets('show, background/foreground, then tap', (tester) async {
      await tester.pumpWidget(app(
        child: const Tooltip(message: 'Mute', child: Icon(Icons.mic)),
      ));
      await tester.longPress(find.byType(Tooltip));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
    });

    testWidgets('tooltip in scrolling list, scrolled out and back',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemCount: 30,
            itemBuilder: (context, i) => Tooltip(
              message: 'Item $i',
              child: SizedBox(height: 80, child: Text('row $i')),
            ),
          ),
        ),
      ));
      await tester.longPress(find.text('row 0'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
      await tester.fling(find.byType(ListView), const Offset(0, -2000), 2000);
      await tester.pumpAndSettle();
      expect(takeError(tester), isNull);
      await tester.fling(find.byType(ListView), const Offset(0, 2000), 2000);
      await tester.pumpAndSettle();
      expect(takeError(tester), isNull);
      await tester.longPress(find.text('row 0'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);
    });
  });

  group('Lead 1: VoiceCallScreen mute tooltip', () {
    testWidgets('voice-call screen mute button: long press, tap while showing, tap elsewhere',
        (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: VoiceCallScreen(voice: voice),
      ));
      await tester.pump();

      final muteBtn = find.byKey(const Key('voiceCallMuteButton'));
      expect(muteBtn, findsOneWidget);

      // Long press mute button to trigger Tooltip ('Mute')
      await tester.longPress(muteBtn);
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Tap mute button directly while tooltip is active: toggles mute, rebuilds _MuteButton with 'Unmute'
      await tester.tap(muteBtn);
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);
      expect(voice.muted, isTrue);

      // Tap elsewhere to trigger global pointer router dismiss
      await tester.tapAt(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 200));
      expect(takeError(tester), isNull);

      // Long press again to show 'Unmute' tooltip
      await tester.longPress(muteBtn);
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Tap elsewhere
      await tester.tapAt(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 200));
      expect(takeError(tester), isNull);
    });

    testWidgets('voice-call screen mute button: rapid taps flip mute state repeatedly',
        (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: VoiceCallScreen(voice: voice),
      ));
      await tester.pump();

      final muteBtn = find.byKey(const Key('voiceCallMuteButton'));
      for (var i = 0; i < 10; i++) {
        await tester.tap(muteBtn);
        await tester.pump(const Duration(milliseconds: 50));
        expect(takeError(tester), isNull);
      }
      expect(voice.toggleMuteCalls, 10);
    });

    testWidgets('voice-call screen mute button: long press, close button tapped while tooltip visible',
        (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => VoiceCallScreen(voice: voice),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final muteBtn = find.byKey(const Key('voiceCallMuteButton'));
      await tester.longPress(muteBtn);
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Tap close button while mute tooltip is visible: pops screen while tooltip is active
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(takeError(tester), isNull);
      expect(find.byType(VoiceCallScreen), findsNothing);

      // Tap elsewhere on the parent screen
      await tester.tapAt(const Offset(50, 50));
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);
    });

    testWidgets('voice-call screen: multi-pointer touches on mute button',
        (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: VoiceCallScreen(voice: voice),
      ));
      await tester.pump();

      final muteCenter = tester.getCenter(find.byKey(const Key('voiceCallMuteButton')));

      // Two fingers down simultaneously on or near the mute button
      final g1 = await tester.startGesture(muteCenter, pointer: 1);
      final g2 = await tester.startGesture(muteCenter + const Offset(5, 5), pointer: 2);
      await tester.pump(const Duration(milliseconds: 300));
      expect(takeError(tester), isNull);

      await g1.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);

      await g2.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(takeError(tester), isNull);
    });

    testWidgets('voice-call screen: controller state changes while mute tooltip is showing',
        (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: VoiceCallScreen(voice: voice),
      ));
      await tester.pump();

      final muteBtn = find.byKey(const Key('voiceCallMuteButton'));
      await tester.longPress(muteBtn);
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // External mute state toggle from session
      await voice.toggleMute();
      await tester.pump();
      expect(takeError(tester), isNull);

      // External quiet chip appearance
      voice.setQuiet(true);
      await tester.pump();
      expect(takeError(tester), isNull);

      // Tap AymaQuietChip unmute while mute tooltip is showing
      await tester.tap(find.byKey(const Key('aymaQuietUnmute')));
      await tester.pump();
      expect(takeError(tester), isNull);

      // Call ends while tooltip showing
      voice.setPhase(VoiceSessionPhase.idle);
      await tester.pump();
      expect(takeError(tester), isNull);
    });

    testWidgets('voice-call screen: push, show tooltip, pop, reopen, tap mute',
        (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    fullscreenDialog: true,
                    builder: (_) => VoiceCallScreen(voice: voice),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();

      // Open screen
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Long press mute button
      await tester.longPress(find.byKey(const Key('voiceCallMuteButton')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Pop
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Reopen
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Tap mute
      await tester.tap(find.byKey(const Key('voiceCallMuteButton')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);
      expect(voice.muted, isTrue);
    });
  });

  group('Lead 2: Composer tooltips', () {
    testWidgets('chat composer: text mode tooltips (photo, send, talk)',
        (tester) async {
      final textController = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(textController.dispose);
      addTearDown(focusNode.dispose);

      var text = '';
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => testComposer(
              controller: textController,
              focusNode: focusNode,
              mode: ComposerMode.text,
              canSend: text.isNotEmpty,
              onAttach: () {},
              onMicPressed: () {},
              onSend: () {},
            ),
          ),
        ),
      ));
      await tester.pump();

      // Photo button tooltip ('Attach a photo')
      final photoBtn = find.byTooltip('Attach a photo');
      expect(photoBtn, findsOneWidget);
      await tester.longPress(photoBtn);
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Tap elsewhere to dismiss
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 200));
      expect(takeError(tester), isNull);

      // Talk button tooltip ('Talk to Ayma')
      final talkBtn = find.byTooltip('Talk to Ayma');
      expect(talkBtn, findsOneWidget);
      await tester.longPress(talkBtn);
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Enter text to reveal send button
      textController.text = 'Hello';
      text = 'Hello';
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          body: testComposer(
            controller: textController,
            focusNode: focusNode,
            mode: ComposerMode.text,
            canSend: true,
            onAttach: () {},
            onMicPressed: () {},
            onSend: () {},
          ),
        ),
      ));
      await tester.pump();

      final sendBtn = find.byTooltip('Send');
      expect(sendBtn, findsOneWidget);
      await tester.longPress(sendBtn);
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      await tester.tap(sendBtn);
      await tester.pump();
      expect(takeError(tester), isNull);
    });

    testWidgets('chat composer: voice mode mute button tooltip tap and unmute',
        (tester) async {
      final textController = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(textController.dispose);
      addTearDown(focusNode.dispose);
      var muted = false;

      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => testComposer(
              controller: textController,
              focusNode: focusNode,
              mode: ComposerMode.listening,
              muted: muted,
              onMuteTap: () => setState(() => muted = !muted),
              onExpandTap: () {},
              onStopPressed: () {},
              statusLabel: 'Listening…',
            ),
          ),
        ),
      ));
      await tester.pump();

      final muteBtn = find.byTooltip('Mute');
      expect(muteBtn, findsOneWidget);

      await tester.longPress(muteBtn);
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Tap mute button directly while tooltip is active
      await tester.tap(muteBtn);
      await tester.pump();
      expect(takeError(tester), isNull);
      expect(muted, isTrue);

      // Tooltip updates to 'Unmute'
      expect(find.byTooltip('Unmute'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 200));
      expect(takeError(tester), isNull);
    });

    testWidgets('chat composer: full-screen voice view label tooltip and expand tap',
        (tester) async {
      final textController = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(textController.dispose);
      addTearDown(focusNode.dispose);
      var expanded = false;

      await tester.pumpWidget(app(
        child: testComposer(
          controller: textController,
          focusNode: focusNode,
          mode: ComposerMode.listening,
          muted: false,
          onMuteTap: () {},
          onExpandTap: () => expanded = true,
          onStopPressed: () {},
          statusLabel: 'Listening…',
        ),
      ));
      await tester.pump();

      final labelTooltip = find.byTooltip('Open full-screen voice view');
      expect(labelTooltip, findsOneWidget);

      await tester.longPress(labelTooltip);
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      await tester.tap(labelTooltip);
      await tester.pump();
      expect(takeError(tester), isNull);
      expect(expanded, isTrue);
    });

    testWidgets('chat composer: mode transition text -> connecting -> listening -> text while tooltip active',
        (tester) async {
      final textController = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(textController.dispose);
      addTearDown(focusNode.dispose);
      var mode = ComposerMode.text;

      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                testComposer(
                  controller: textController,
                  focusNode: focusNode,
                  mode: mode,
                  muted: false,
                  onMuteTap: () {},
                  onExpandTap: () {},
                  onStopPressed: () {},
                  statusLabel: 'Listening…',
                ),
                TextButton(
                  onPressed: () => setState(() => mode = ComposerMode.connecting),
                  child: const Text('toConnecting'),
                ),
                TextButton(
                  onPressed: () => setState(() => mode = ComposerMode.listening),
                  child: const Text('toListening'),
                ),
                TextButton(
                  onPressed: () => setState(() => mode = ComposerMode.text),
                  child: const Text('toText'),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();

      // Show tooltip in text mode
      await tester.longPress(find.byTooltip('Attach a photo'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Switch to connecting mode while tooltip is displayed
      await tester.tap(find.text('toConnecting'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);

      // Switch to listening mode
      await tester.tap(find.text('toListening'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);

      // Long press mute in listening mode
      await tester.longPress(find.byTooltip('Mute'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Switch back to text mode while mute tooltip is displayed
      await tester.tap(find.text('toText'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);

      // Tap elsewhere
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 200));
      expect(takeError(tester), isNull);
    });
  });

  group('Lead 3: Tab-bar manual-trigger tooltip', () {
    testWidgets('ayma tab bar: orb tab rapid taps (manual trigger mode)',
        (tester) async {
      final selected = <int>[];
      var holds = 0;

      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          bottomNavigationBar: AymaTabBar(
            index: 0,
            voice: null,
            onSelected: selected.add,
            onOrbLongPress: () => holds++,
          ),
        ),
      ));
      await tester.pump();

      final orb = find.byTooltip('Ayma');
      expect(orb, findsOneWidget);

      for (var i = 0; i < 10; i++) {
        await tester.tap(orb);
        await tester.pump(const Duration(milliseconds: 50));
        expect(takeError(tester), isNull);
      }
      expect(selected.length, 10);
      expect(holds, 0);
    });

    testWidgets('ayma tab bar: orb tab 500ms hold (arena threshold) and release',
        (tester) async {
      final selected = <int>[];
      var holds = 0;

      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          bottomNavigationBar: AymaTabBar(
            index: 0,
            voice: null,
            onSelected: selected.add,
            onOrbLongPress: () => holds++,
          ),
        ),
      ));
      await tester.pump();

      final orbCenter = tester.getCenter(find.byTooltip('Ayma'));
      final g = await tester.startGesture(orbCenter);
      // Wait past default long-press 500ms threshold
      await tester.pump(const Duration(milliseconds: 550));
      expect(takeError(tester), isNull);

      // Release before 1s hold completes
      await g.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);
      expect(selected, [0]);
      expect(holds, 0);
    });

    testWidgets('ayma tab bar: orb tab 1s hold fires onOrbLongPress',
        (tester) async {
      final selected = <int>[];
      var holds = 0;

      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          bottomNavigationBar: AymaTabBar(
            index: 0,
            voice: null,
            onSelected: selected.add,
            onOrbLongPress: () => holds++,
          ),
        ),
      ));
      await tester.pump();

      final orbCenter = tester.getCenter(find.byTooltip('Ayma'));
      final g = await tester.startGesture(orbCenter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 950));
      expect(holds, 0);

      await tester.pump(const Duration(milliseconds: 100));
      expect(holds, 1);
      await g.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);
      expect(selected, isEmpty);
    });

    testWidgets('ayma tab bar: multi-pointer (hold orb with pointer 1, tap chat with pointer 2)',
        (tester) async {
      final selected = <int>[];
      var holds = 0;

      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          bottomNavigationBar: AymaTabBar(
            index: 0,
            voice: null,
            onSelected: selected.add,
            onOrbLongPress: () => holds++,
          ),
        ),
      ));
      await tester.pump();

      final orbCenter = tester.getCenter(find.byTooltip('Ayma'));
      final messagesCenter = tester.getCenter(find.byTooltip('Messages'));

      // Pointer 1 starts gesture on orb
      final g1 = await tester.startGesture(orbCenter, pointer: 1);
      await tester.pump(const Duration(milliseconds: 300));
      expect(takeError(tester), isNull);

      // Pointer 2 taps Messages tab
      final g2 = await tester.startGesture(messagesCenter, pointer: 2);
      await tester.pump(const Duration(milliseconds: 50));
      await g2.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);

      await g1.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);
    });

    testWidgets('ayma tab bar: non-orb tab long press tooltip, then tap orb',
        (tester) async {
      final selected = <int>[];
      var holds = 0;

      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          bottomNavigationBar: AymaTabBar(
            index: 0,
            voice: null,
            onSelected: selected.add,
            onOrbLongPress: () => holds++,
          ),
        ),
      ));
      await tester.pump();

      // Long press Messages tab (which uses default triggerMode: longPress)
      await tester.longPress(find.byTooltip('Messages'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Tap orb tab while Chat tooltip is active
      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);

      // Tap elsewhere
      await tester.tapAt(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 200));
      expect(takeError(tester), isNull);
    });
  });

  group('Semantics & Storm interactions (FLUTTER-3R window conditions)', () {
    testWidgets('voice-call screen mute tooltip with Semantics enabled',
        (tester) async {
      final semanticsHandle = tester.ensureSemantics();

      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: VoiceCallScreen(voice: voice),
      ));
      await tester.pump();

      final muteBtn = find.byKey(const Key('voiceCallMuteButton'));
      await tester.longPress(muteBtn);
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      await tester.tap(muteBtn);
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);

      await tester.tapAt(const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 200));
      expect(takeError(tester), isNull);

      semanticsHandle.dispose();
    });

    testWidgets('ayma tab bar manual trigger with Semantics enabled',
        (tester) async {
      final semanticsHandle = tester.ensureSemantics();

      final selected = <int>[];
      var holds = 0;
      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          bottomNavigationBar: AymaTabBar(
            index: 0,
            voice: null,
            onSelected: selected.add,
            onOrbLongPress: () => holds++,
          ),
        ),
      ));
      await tester.pump();

      final orb = find.byTooltip('Ayma');
      await tester.tap(orb);
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);

      final orbCenter = tester.getCenter(orb);
      final g = await tester.startGesture(orbCenter);
      await tester.pump(const Duration(milliseconds: 1100));
      await g.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);

      semanticsHandle.dispose();
    });

    testWidgets('rapid global pointer-down flood across tooltips with Semantics enabled',
        (tester) async {
      final semanticsHandle = tester.ensureSemantics();

      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      final textController = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(textController.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          body: Column(
            children: [
              testComposer(
                controller: textController,
                focusNode: focusNode,
                mode: ComposerMode.listening,
                muted: false,
                onMuteTap: () {},
                onExpandTap: () {},
                onStopPressed: () {},
                statusLabel: 'Listening…',
              ),
              const Expanded(
                child: Row(
                  children: [
                    Tooltip(message: 'Item A', child: Icon(Icons.star)),
                    Tooltip(message: 'Item B', child: Icon(Icons.favorite)),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: AymaTabBar(
            index: 0,
            voice: voice,
            onSelected: (_) {},
            onOrbLongPress: () {},
          ),
        ),
      ));
      await tester.pump();

      // Flood 30 rapid pointer-down events at varied coordinates
      for (var i = 0; i < 30; i++) {
        await tester.tapAt(Offset(10.0 + (i * 12.0) % 300, 50.0 + (i * 25.0) % 500));
        await tester.pump(const Duration(milliseconds: 20));
        expect(takeError(tester), isNull);
      }

      semanticsHandle.dispose();
    });
  });

  group('Full integrated screen flows', () {
    testWidgets('chat screen flow: composer, tab bar, open full voice screen, mute, close',
        (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      final textController = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(textController.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(
          body: ListenableBuilder(
            listenable: voice,
            builder: (context, _) => Column(
              children: [
                Expanded(
                  child: Center(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          fullscreenDialog: true,
                          builder: (_) => VoiceCallScreen(voice: voice),
                        ),
                      ),
                      child: const Text('openVoiceCallScreen'),
                    ),
                  ),
                ),
                testComposer(
                  controller: textController,
                  focusNode: focusNode,
                  mode: ComposerMode.listening,
                  muted: voice.muted,
                  onMuteTap: voice.toggleMute,
                  onExpandTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      fullscreenDialog: true,
                      builder: (_) => VoiceCallScreen(voice: voice),
                    ),
                  ),
                  onStopPressed: voice.stop,
                  statusLabel: 'Listening…',
                ),
              ],
            ),
          ),
          bottomNavigationBar: AymaTabBar(
            index: 0,
            voice: voice,
            onSelected: (_) {},
            onOrbLongPress: () {},
          ),
        ),
      ));
      await tester.pump();

      // Long press composer mute tooltip
      await tester.longPress(find.byTooltip('Mute'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Open VoiceCallScreen
      await tester.tap(find.text('openVoiceCallScreen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(VoiceCallScreen), findsOneWidget);

      // Long press voice call mute button
      await tester.longPress(find.byKey(const Key('voiceCallMuteButton')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(takeError(tester), isNull);

      // Tap mute
      await tester.tap(find.byKey(const Key('voiceCallMuteButton')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);
      expect(voice.muted, isTrue);

      // Close VoiceCallScreen
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(VoiceCallScreen), findsNothing);

      // Back on main screen: composer shows 'Unmute' tooltip
      expect(find.byTooltip('Unmute'), findsOneWidget);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);
      expect(voice.muted, isFalse);

      // Tab bar orb tap
      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(takeError(tester), isNull);
    });
  });
}
