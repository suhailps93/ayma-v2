import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/chat_service.dart';
import '../services/ids.dart';
import '../services/transcript_store.dart';
import '../services/voice_session_controller.dart';
import '../services/voice_transport.dart';
import '../theme.dart';
import 'chat_composer.dart';
import 'out_of_credits.dart';

/// What one Ask Ayma turn is scoped to — either a highlighted passage inside
/// a section, or one entry of the structured career timeline. Carries exactly
/// what `skills/story_edit.py`'s tools need: `pageId`/`selectedText` map to
/// `story_page_id`/`story_passage`; `timelineEntryId` maps to the newer
/// `story_timeline_entry_id` field, which scopes `edit_career_timeline_entry`
/// / `delete_career_timeline_entry` instead.
class AskAymaContext {
  const AskAymaContext({
    required this.pageId,
    this.selectedText = '',
    this.sectionTitle = '',
    this.timelineEntryId = '',
    this.timelineEntryLabel = '',
    this.isPrivate = false,
  });

  final String pageId;
  final String selectedText;
  final String sectionTitle;
  final String timelineEntryId;
  final String timelineEntryLabel;

  /// Whether the tapped passage is currently private — decides which single
  /// privacy toggle heads the quick-suggestion chips (see
  /// [_quickSuggestionsFor]). Meaningless (and ignored) for a timeline entry.
  final bool isPrivate;

  bool get isTimelineEntry => timelineEntryId.isNotEmpty;
}

/// Opens the Ask Ayma overlay: a dark scrim, a bottom sheet sliding up over
/// the document (Android back / tap-outside dismiss it, same as any modal
/// sheet), carrying the exact context above into the real `/chat` (or
/// `/chat/stream`) pipeline — the same one ordinary passage edits already use.
///
/// [onExchange] fires after every reply Ayma gives while the sheet is open
/// (not just once at the end) so the caller can quietly re-fetch the section
/// and flash the sentence that changed while the user is still mid-conversation,
/// without leaving the document. Returns once the sheet is dismissed.
Future<void> showAskAymaOverlay(
  BuildContext context, {
  required ApiClient api,
  required AskAymaContext ctx,
  VoidCallback? onExchange,
  @visibleForTesting ApiClient? voiceApiClient,
  @visibleForTesting VoiceTransport Function()? voiceTransportFactory,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (_) => _AskAymaSheet(
      api: api,
      ctx: ctx,
      onExchange: onExchange,
      voiceApiClient: voiceApiClient,
      voiceTransportFactory: voiceTransportFactory,
    ),
  );
}

class _Msg {
  const _Msg(this.role, this.text);
  final String role; // 'user' | 'ayma'
  final String text;
}

/// The quick-suggestion chips, in order. The privacy toggle and delete always
/// lead — ahead of the content-editing suggestions — regardless of which way
/// the toggle currently points: [isPrivate] only picks its label ("Make
/// public" vs "Make private"), never its position.
List<String> _quickSuggestionsFor(bool isPrivate) => [
      isPrivate ? 'Make public' : 'Make private',
      'Delete',
      'Make this more concise',
      'Add more details',
      'Rewrite in my tone',
    ];

class _AskAymaSheet extends StatefulWidget {
  const _AskAymaSheet({
    required this.api,
    required this.ctx,
    this.onExchange,
    this.voiceApiClient,
    this.voiceTransportFactory,
  });

  final ApiClient api;
  final AskAymaContext ctx;
  final VoidCallback? onExchange;

  /// Test seams only — production always leaves these null so the sheet's own
  /// [VoiceSessionController] (see [_AskAymaSheetState._voice]) builds its
  /// default real [ApiClient] / [LiveKitVoiceTransport]. A test supplies a
  /// mocked [ApiClient] and a [FakeVoiceTransport]-backed factory instead, the
  /// same seam [VoiceSessionController] itself already exposes.
  final ApiClient? voiceApiClient;
  final VoiceTransport Function()? voiceTransportFactory;

  @override
  State<_AskAymaSheet> createState() => _AskAymaSheetState();
}

class _AskAymaSheetState extends State<_AskAymaSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _picker = ImagePicker();
  final _chatService = ChatService();
  final String _sessionId = newSessionId();

  // Voice is push-to-talk here, not full duplex: the sheet's story-passage
  // context (`storyPageId`/`storyPassage`/`storyTimelineEntryId`) only reaches
  // the backend through `/chat`/`/chat/stream` (see `_send`) — the LiveKit
  // voice agent (`agent.py`) never binds the Your Story edit tools at all
  // (`skills.make_livekit_tools` wires only the base registry + app_control,
  // never `story_edit`'s `_STORY_REGISTRY`), so a live voice turn has no way
  // to act on this passage today. Instead: tap the mic, talk, and the moment
  // Gemini Live's own turn-detection finalizes what you said, that transcript
  // is sent through the exact same `_send()` text path everything else here
  // uses — story context intact — and the voice session is torn down before
  // Ayma's spoken reply ever plays (nothing to say to a scoped edit request
  // over open air). The composer still shows real listening/thinking state
  // off the controller's live mic/agent amplitude while this is happening.
  late final TranscriptStore _voiceStore = TranscriptStore();
  late final VoiceSessionController _voice = VoiceSessionController(
    transcriptStore: _voiceStore,
    sessionId: newSessionId(),
    apiClient: widget.voiceApiClient,
    transportFactory: widget.voiceTransportFactory,
  );
  bool _listening = false;

  final List<_Msg> _messages = [];
  bool _sending = false;
  String? _statusLabel;
  File? _pendingImage;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    _voice.addListener(_onVoiceChanged);
    _voiceStore.addListener(_onVoiceTranscriptChanged);
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoiceChanged);
    _voiceStore.removeListener(_onVoiceTranscriptChanged);
    // This sheet always owns `_voice` (unlike ChatScreen's, which is handed
    // down from the shared shell and must outlive tab switches) — dispose it
    // unconditionally. It tears down its LiveKit room/subscriptions and clears
    // `VoiceSessionController.active` if it was the active one, whether or not
    // a capture was actually in progress, so the sheet closing mid-turn can
    // never leak a live connection.
    _voice.dispose();
    _voiceStore.dispose();
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onVoiceChanged() {
    if (!mounted) return;
    if (_listening && _voice.phase == VoiceSessionPhase.error) {
      final msg = _voice.errorMessage ?? "Couldn't start voice.";
      final capped = _voice.cappedError;
      setState(() => _listening = false);
      if (capped) {
        showOutOfCreditsSnack(context, message: msg);
      } else {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(msg)));
      }
      return;
    }
    setState(() {});
  }

  /// Fires on every voice-store change while push-to-talk is capturing —
  /// looks for the moment the user's utterance finalizes (Gemini Live's own
  /// turn-detection, not a manual stop) and routes it into [_send] exactly
  /// like typed text.
  void _onVoiceTranscriptChanged() {
    if (!_listening) return;
    final turns = _voiceStore.turns;
    if (turns.isEmpty) return;
    final last = turns.last;
    if (last.role != TurnRole.user || !last.isFinal) return;
    final text = last.text;
    setState(() => _listening = false);
    unawaited(_voice.stop());
    if (text.trim().isNotEmpty) _send(text);
  }

  /// Mic tapped from the idle composer — starts a push-to-talk capture,
  /// unless the main Ayma tab already has a live voice call going, in which
  /// case this sheet declines rather than opening a second parallel LiveKit
  /// connection.
  Future<void> _onMicPressed() async {
    if (_sending || _listening) return;
    final other = VoiceSessionController.active;
    if (other != null && other != _voice && other.isActive) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
            content: Text(
                "You're already on a voice call with Ayma — finish that "
                'first, then try again here.')));
      return;
    }
    setState(() => _listening = true);
    await _voice.start();
  }

  /// The composer's "End voice" button tapped mid-capture — a deliberate
  /// cancel, same as ending a call in the main chat screen: nothing is sent.
  void _onVoiceStopPressed() {
    if (!_listening) return;
    setState(() => _listening = false);
    unawaited(_voice.stop());
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _attach() async {
    try {
      final x = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (x == null || !mounted) return;
      setState(() => _pendingImage = File(x.path));
    } catch (_) {
      // Picker cancelled/unavailable — nothing to attach, no error surface.
    }
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _controller.text).trim();
    final image = _pendingImage;
    if (_sending || (text.isEmpty && image == null)) return;

    final window = [for (final m in _messages) {'role': m.role, 'text': m.text}];
    setState(() {
      _sending = true;
      _messages.add(_Msg('user', text.isEmpty ? '(shared a photo)' : text));
      _controller.clear();
      _pendingImage = null;
      _statusLabel = 'Thinking…';
    });
    _scrollToEnd();

    var imagePath = '';
    if (image != null) {
      try {
        final up = await _chatService.uploadChatImage(image);
        imagePath = up.storagePath;
      } catch (_) {
        // Upload failed — still send the text, just without the photo.
      }
    }

    try {
      ChatResult? result;
      try {
        await for (final ev in widget.api.chatStream(
          text.isEmpty ? '(shared a photo)' : text,
          sessionId: _sessionId,
          recentTurns: window,
          imagePath: imagePath,
          storyPageId: widget.ctx.pageId,
          storyPassage: widget.ctx.isTimelineEntry ? '' : widget.ctx.selectedText,
          storyTimelineEntryId: widget.ctx.timelineEntryId,
        )) {
          if (!mounted) return;
          if (ev is ChatStatus) {
            setState(() => _statusLabel = ev.label);
          } else if (ev is ChatReplyEvent) {
            result = ev.result;
          }
        }
      } on ApiException {
        result = await widget.api.chat(
          text.isEmpty ? '(shared a photo)' : text,
          sessionId: _sessionId,
          recentTurns: window,
          imagePath: imagePath,
          storyPageId: widget.ctx.pageId,
          storyPassage: widget.ctx.isTimelineEntry ? '' : widget.ctx.selectedText,
          storyTimelineEntryId: widget.ctx.timelineEntryId,
        );
      }
      if (!mounted) return;
      final r = result;
      if (r == null) {
        setState(() => _messages.add(
            const _Msg('ayma', "Sorry, that didn't go through. Try again?")));
      } else {
        setState(() => _messages.add(_Msg('ayma', r.reply)));
        if (r.usageCapped) {
          showOutOfCreditsSnack(context);
        } else {
          // Let the document catch up in place — while the sheet is still
          // open, not just once it closes.
          widget.onExchange?.call();
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _messages.add(
          const _Msg('ayma', "Sorry, that didn't go through. Try again?")));
    } finally {
      if (mounted) setState(() { _sending = false; _statusLabel = null; });
      _scrollToEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final mq = MediaQuery.of(context);
    final selected = widget.ctx.isTimelineEntry
        ? widget.ctx.timelineEntryLabel
        : widget.ctx.selectedText;

    // Driven by our own flag, not `_voice.isActive` — the UI should flip back
    // to text the instant we decide to stop (finalized transcript, manual
    // stop, or an error), not wait on the controller's own async teardown to
    // actually reach `idle` first.
    final voiceActive = _listening;
    final composerMode = !voiceActive
        ? ComposerMode.text
        : (_voice.agentSpeaking
            ? ComposerMode.aiSpeaking
            : ComposerMode.listening);
    String? voiceStatus;
    if (voiceActive) {
      voiceStatus = switch (_voice.phase) {
        VoiceSessionPhase.connecting => 'Connecting…',
        VoiceSessionPhase.waking => 'Waking Ayma…',
        _ => _voice.muted
            ? 'Muted'
            : (_voice.agentSpeaking
                ? 'Ayma is speaking…'
                : (_voice.activeToolLabel ?? 'Listening…')),
      };
    }

    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: FractionallySizedBox(
        heightFactor: mq.viewInsets.bottom > 0 ? 0.86 : 0.55,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ac.bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            border: Border(
              top: BorderSide(color: ac.lineSoft, width: 0.5),
              left: BorderSide(color: ac.lineSoft, width: 0.5),
              right: BorderSide(color: ac.lineSoft, width: 0.5),
            ),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: ac.lineSoft,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 16, color: ac.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Edit with Ayma',
                          style: AymaType.serif(size: 19, color: ac.fg)),
                    ),
                    Semantics(
                      button: true,
                      label: 'Close',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => Navigator.of(context).pop(),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.close, size: 20, color: ac.fgDim),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  "Tell Ayma what you'd like to change, add, or refine.",
                  style: AymaType.sans(size: 13, color: ac.fgMute),
                ),
              ),
              if (selected.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: _SelectedQuote(text: selected),
                ),
              Expanded(
                child: _messages.isEmpty && _statusLabel == null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: _QuickChips(
                            suggestions: _quickSuggestionsFor(widget.ctx.isPrivate),
                            onPick: (s) {
                              _controller.text = s;
                              _send(s);
                            },
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                        itemCount: _messages.length + (_statusLabel != null ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= _messages.length) {
                            return _StatusRow(label: _statusLabel!);
                          }
                          return _MessageRow(msg: _messages[i]);
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                  child: ChatComposer(
                    mode: composerMode,
                    controller: _controller,
                    focusNode: _focus,
                    canSend: !_sending &&
                        (_controller.text.trim().isNotEmpty || _pendingImage != null),
                    onSend: _send,
                    onAttach: _attach,
                    onMicPressed: _onMicPressed,
                    onStopPressed: _onVoiceStopPressed,
                    onMuteTap: () => _voice.toggleMute(),
                    muted: _voice.muted,
                    userAmplitude: _voice.micLevel,
                    aiAmplitude: _voice.aymaLevel,
                    statusLabel: voiceStatus,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectedQuote extends StatelessWidget {
  const _SelectedQuote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: ac.accent, width: 2.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SELECTED TEXT',
              style: AymaType.mono(size: 9, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.4)),
          const SizedBox(height: 6),
          Text(
            '"$text"',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: AymaType.serif(size: 14, italic: true, color: ac.fg)
                .copyWith(height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _QuickChips extends StatelessWidget {
  const _QuickChips({required this.suggestions, required this.onPick});
  final List<String> suggestions;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in suggestions)
          InkWell(
            onTap: () => onPick(s),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: ac.bgElev,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: ac.lineSoft, width: 0.5),
              ),
              child: Text(s, style: AymaType.sans(size: 12.5, color: ac.fgDim)),
            ),
          ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 12, height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 1.6, color: ac.accent),
          ),
          const SizedBox(width: 10),
          Text(label, style: AymaType.sans(size: 12.5, color: ac.fgMute)),
        ],
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.msg});
  final _Msg msg;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isUser = msg.role == 'user';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
          child: isUser
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: ac.accentSoft,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(msg.text,
                      style: AymaType.sans(size: 14, color: ac.fg)),
                )
              : Text(
                  msg.text,
                  style: AymaType.serif(size: 15, color: ac.fg)
                      .copyWith(height: 1.4),
                ),
        ),
      ),
    );
  }
}
