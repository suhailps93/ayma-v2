import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/app_context.dart';
import '../services/assist_context.dart';
import '../services/assistant_service.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_toast.dart';
import 'main_shell_screen.dart';

/// Ayma Assistant — the surface a summon opens.
///
/// Reached three ways:
///  * a real summon (long-press Home / assistant gesture) while Ayma
///    is the default digital assistant: Android's Assist API hands the
///    foreground app's screen to `AymaAssistantSession`, which opens
///    this screen with the capture already held in
///    [AssistantSessionStore];
///  * Ayma's settings ("Ayma Assistant" row), where it doubles as the
///    feature's home: status, the deep link to make Ayma the default
///    assistant, and the privacy explainer;
///  * Ayma's command surface (registry destination `assistant`).
///
/// What she can do here: describe the captured screen locally, answer
/// questions about it (the ask rides `/chat`'s screen-context params
/// with `screen == 'external_app'`), and hand the screen into the main
/// chat/voice surface as [AppContext] so guidance continues there.
///
/// COPILOT-HANDOFF: the "Guide me" button currently hands off through
/// chat/voice with the screen in context. The screen-share co-pilot
/// (branch `fleet/copilot-highlight`, `CopilotScreen` at `/copilot`)
/// is the step-by-step highlight surface; when both branches are on
/// staging, point this button at `CopilotScreen.path` and seed
/// `CopilotService` with [AssistCapture.screenshotBytes] as its first
/// frame — the one wiring step that cannot exist until both land.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, this.api, this.service, this.capture});

  static const path = '/assistant';

  final ApiClient? api;
  final AssistantService? service;

  /// A capture supplied directly (tests, layout matrix). When null the
  /// screen resolves one from [AssistantSessionStore] / the platform
  /// channel, in that order.
  final AssistCapture? capture;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen>
    with WidgetsBindingObserver {
  late final ApiClient _api = widget.api ?? ApiClient();
  late final AssistantService _service =
      widget.service ?? AssistantService.instance;

  final _questionController = TextEditingController();

  AssistCapture? _capture;
  bool? _isDefault;
  bool _loading = true;
  bool _asking = false;
  String? _reply;
  String? _askError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _capture = widget.capture ?? AssistantSessionStore.instance.current;
    if (_capture != null) {
      AssistantSessionStore.instance.hold(_capture!);
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _questionController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the system default-assistant settings: re-read
    // the status so the row reflects the user's choice immediately.
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshStatus());
    }
  }

  Future<void> _load() async {
    if (_capture == null) {
      _capture = await _service.takePendingAssist();
      if (_capture != null) {
        AssistantSessionStore.instance.hold(_capture!);
      }
    }
    await _refreshStatus();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshStatus() async {
    final isDefault = await _service.isDefaultAssistant();
    if (mounted) setState(() => _isDefault = isDefault);
  }

  Future<void> _ask(String question) async {
    final capture = _capture;
    final q = question.trim();
    if (capture == null || q.isEmpty || _asking) return;
    setState(() {
      _asking = true;
      _askError = null;
    });
    final params = capture.snapshot.chatScreenParams();
    try {
      final result = await _api.chat(
        q,
        screen: params.screen,
        screenSubjectName: params.subjectName,
        screenNote: params.note,
        screenDetail: params.detail,
        screenVisible: params.visible,
      );
      if (!mounted) return;
      setState(() => _reply = result.reply);
    } on ApiException catch (e) {
      if (mounted) setState(() => _askError = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _askError = 'Something went wrong asking Ayma.');
      }
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// Hands the captured screen into the main chat/voice surface as the
  /// live [AppContext], so a voice call or chat turn there already
  /// knows what the user was looking at. See the COPILOT-HANDOFF note
  /// on the widget for the co-pilot highlight wiring at merge time.
  void _continueWithAyma({required bool guide}) {
    final snap = _capture?.snapshot;
    if (snap != null && snap.hasScreenContent) {
      AppContext.instance.set(
        screen: 'external_app',
        subjectName: snap.friendlyAppName,
        note: snap.foregroundPackage,
        detail: snap.detailSummary(),
      );
    }
    AymaToast.show(
      context,
      guide
          ? 'Ayma has this screen in context — ask her what to tap, '
              'step by step.'
          : 'Ayma has this screen in context — keep asking her here.',
      kind: AymaToastKind.success,
    );
    context.go(MainShellScreen.path);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Ayma Assistant'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _statusSection(ac),
                if (_capture != null) _captureSection(ac),
              ],
            ),
    );
  }

  Widget _statusSection(AymaTokens ac) {
    final isDefault = _isDefault;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Default assistant',
            style: AymaType.mono(size: 11, color: ac.fgMute),
          ),
        ),
        ListTile(
          key: const Key('assistant_status'),
          leading: Icon(
            isDefault == true
                ? Icons.check_circle_outline
                : Icons.smart_button_outlined,
            color: ac.fgDim,
          ),
          title: Text(
            isDefault == true
                ? 'Ayma is your default assistant'
                : 'Make Ayma your default assistant',
            style: AymaType.sans(size: 15, color: ac.fg),
          ),
          subtitle: Text(
            isDefault == true
                ? 'Long-press Home in any app to summon her there.'
                : AssistPrivacy.settingsBlurb,
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: FilledButton.tonal(
            key: const Key('assistant_open_settings'),
            onPressed: () => _service.openDefaultAssistantSettings(),
            child: const Text('Open assistant settings'),
          ),
        ),
        Divider(color: ac.lineSoft),
      ],
    );
  }

  Widget _captureSection(AymaTokens ac) {
    final capture = _capture!;
    final snap = capture.snapshot;
    if (!snap.screenDataAllowed || !snap.hasScreenContent) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ayma could not see that screen',
              style: AymaType.sans(size: 15, color: ac.fg),
            ),
            const SizedBox(height: 8),
            Text(
              AssistPrivacy.noScreenDataNote,
              style: AymaType.sans(size: 13, soft: true, color: ac.fgMute),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'What Ayma can see',
            style: AymaType.mono(size: 11, color: ac.fgMute),
          ),
        ),
        ListTile(
          key: const Key('assistant_foreground_app'),
          leading: Icon(Icons.apps_outlined, color: ac.fgDim),
          title: Text(
            snap.friendlyAppName,
            style: AymaType.sans(size: 15, color: ac.fg),
          ),
          subtitle: Text(
            snap.foregroundPackage,
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
        ),
        if (capture.screenshotBytes != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                capture.screenshotBytes!,
                key: const Key('assistant_screenshot'),
                fit: BoxFit.cover,
                height: 220,
                width: double.infinity,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            snap.describe(),
            style: AymaType.sans(size: 14, color: ac.fg),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            AssistPrivacy.sessionNote,
            style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            key: const Key('assistant_question_field'),
            controller: _questionController,
            decoration: const InputDecoration(
              hintText: 'Ask Ayma about this screen',
              border: OutlineInputBorder(),
            ),
            onSubmitted: _ask,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const Key('assistant_ask'),
                onPressed: _asking
                    ? null
                    : () => _ask(_questionController.text),
                child: Text(_asking ? 'Asking...' : 'Ask Ayma'),
              ),
              FilledButton.tonal(
                key: const Key('assistant_describe'),
                onPressed: _asking
                    ? null
                    : () => _ask(AssistSnapshot.describeQuestion),
                child: const Text('Describe this screen'),
              ),
              FilledButton.tonal(
                key: const Key('assistant_guide'),
                onPressed: () => _continueWithAyma(guide: true),
                child: const Text('Guide me on this screen'),
              ),
              TextButton(
                key: const Key('assistant_continue_chat'),
                onPressed: () => _continueWithAyma(guide: false),
                child: const Text('Continue in chat'),
              ),
            ],
          ),
        ),
        if (_askError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              _askError!,
              style: AymaType.sans(size: 13, color: AymaColors.error),
            ),
          ),
        if (_reply != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              _reply!,
              key: const Key('assistant_reply'),
              style: AymaType.sans(size: 14, color: ac.fg),
            ),
          ),
      ],
    );
  }
}
