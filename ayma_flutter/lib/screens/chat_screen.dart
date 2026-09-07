import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/chat_inbox.dart';
import '../services/chat_service.dart';
import '../services/ids.dart';
import '../services/profile_service.dart';
import '../services/transcript_store.dart';
import '../services/voice_session_controller.dart';
import '../theme.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/body_report_view.dart';
import '../widgets/face_report_view.dart';
import '../widgets/markdown_text.dart';
import '../widgets/notification_bell.dart';
import 'preboarding_flow_screen.dart';

/// Ayma chat screen. One [TranscriptStore] backs the view; typed turns and
/// relayed voice-transcript segments flow into it through the same path, so a
/// voice turn renders exactly like a typed one (§1.6, Steps 8–16).
///
/// Visually it follows the design's Talk screen (§14.1): a living orb with a
/// mono state caption, then the transcript as labelled lines — Ayma in serif
/// italic, you in sans — with older turns dimmed.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.apiClient,
    this.voiceController,
    this.transcriptStore,
    this.chatService,
    this.imagePicker,
    this.viewingProfileUid = '',
    this.marketing = false,
    this.profileService,
  });

  static const path = '/chat';

  final ApiClient? apiClient;
  final VoiceSessionController? voiceController;
  final TranscriptStore? transcriptStore;
  final ChatService? chatService;
  final ImagePicker? imagePicker;

  /// Pre-signup `marketing` mode (§3.3): show a "Get started" action that
  /// records the onboarding transition and moves to preboarding.
  final bool marketing;
  final ProfileService? profileService;

  /// When the chat was opened from a specific profile / match card, Ayma gets
  /// that pair's private read into her context (§5.6).
  final String viewingProfileUid;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final String _sessionId = newSessionId();
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final TranscriptStore _store =
      widget.transcriptStore ?? TranscriptStore();
  late final ChatService _chat = widget.chatService ?? ChatService();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();
  late final VoiceSessionController _voice = widget.voiceController ??
      VoiceSessionController(transcriptStore: _store, sessionId: _sessionId);
  final _composerController = TextEditingController();
  final _composerFocus = FocusNode();
  final _scrollController = ScrollController();
  bool _canSend = false;
  bool _sending = false;

  /// Turns loaded from server history on open — not re-posted on dispose.
  int _seededCount = 0;
  bool _loadingHistory = true;

  /// Non-null when the last history load *failed* (auth, non-200, transport,
  /// bad shape). Kept distinct from "no history" so the user gets a retry
  /// affordance instead of a misleading "say hello" — one swallowed cold-start
  /// error would otherwise leave the transcript blank for the whole session
  /// (the Ayma tab is built once and kept alive, so `initState` never re-runs).
  String? _historyError;

  File? _pendingImage;

  @override
  void initState() {
    super.initState();
    _composerController.addListener(() {
      final canSend = _composerController.text.trim().isNotEmpty;
      if (canSend != _canSend) setState(() => _canSend = canSend);
    });
    _store.addListener(_scrollToBottom);
    _loadHistory();
    ChatInbox.instance.pending.addListener(_consumeKickoff);
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeKickoff());
  }

  void _consumeKickoff() {
    final k = ChatInbox.instance.take();
    if (k != null && mounted) _runKickoff(k);
  }

  /// A background skill fired from a button elsewhere in the app (deep dive
  /// today). Show a working turn, run it, drop the result in.
  Future<void> _runKickoff(ChatKickoff k) async {
    if (k.kind != 'deep_dive' || _sending) return;
    final who = k.label.isNotEmpty
        ? k.label
        : (k.targetUid.isEmpty ? 'you' : 'them');
    _store.addPending('Searching the web for $who — this can take a moment…');
    setState(() => _sending = true);
    try {
      final r = await _api.deepDive(targetUid: k.targetUid);
      if (!mounted) return;
      _store.resolvePending(
        r.usageCapped
            ? "I'm out of credits, so I can't run a web search right now — "
                "reload on your profile."
            : r.summary,
        tools: r.usageCapped ? const [] : const ['Researched them online'],
      );
    } catch (_) {
      if (mounted) {
        _store.resolvePending("Couldn't finish that search — try again shortly.");
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _loadHistory() async {
    try {
      final page = await _api.chatHistory(limit: 40);
      final turns = <TranscriptTurn>[];
      for (final m in page.messages) {
        String? url;
        if (m.imagePath.isNotEmpty) {
          try {
            url = await FirebaseStorage.instance
                .ref(m.imagePath)
                .getDownloadURL();
          } catch (_) {/* dropped image — render text only */}
        }
        turns.add(TranscriptTurn(
          role: m.role == 'ayma' ? TurnRole.ayma : TurnRole.user,
          text: m.text,
          source: TurnSource.text,
          imageUrl: url,
        ));
      }
      if (!mounted) return;
      _store.seed(turns);
      _seededCount = turns.length;
      _historyError = null;
    } catch (e) {
      // A load failure must not render the same as an empty history — record it
      // so the view can offer a retry (see `_historyError`).
      debugPrint('chat history load failed: $e');
      if (mounted) _historyError = "Couldn't load your conversation history.";
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  void _retryHistory() {
    if (_loadingHistory) return;
    setState(() {
      _loadingHistory = true;
      _historyError = null;
    });
    _loadHistory();
  }

  @override
  void dispose() {
    // Session-end raw_turns persistence (§1.7 step 8). Fire-and-forget — the
    // screen is going away; the request rides the app's remaining lifetime.
    // Only turns added this session (voice + text) — the seeded history is
    // already persisted server-side.
    final fresh = _store.wireTurns(skip: _seededCount);
    if (fresh.isNotEmpty) {
      try {
        _api.postTurn(_sessionId, fresh).catchError((_) {});
      } catch (_) {/* teardown must not throw */}
    }
    ChatInbox.instance.pending.removeListener(_consumeKickoff);
    _store.removeListener(_scrollToBottom);
    _composerController.dispose();
    _composerFocus.dispose();
    _scrollController.dispose();
    if (widget.voiceController == null) _voice.dispose();
    if (widget.transcriptStore == null) _store.dispose();
    super.dispose();
  }

  Future<void> _toggleVoice() async {
    if (_voice.isActive) {
      await _voice.stop();
    } else {
      await _voice.start();
      if (!mounted) return;
      if (_voice.phase == VoiceSessionPhase.error &&
          _voice.errorMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_voice.errorMessage!)),
        );
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;
      setState(() => _pendingImage = File(picked.path));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open that image.")),
        );
      }
    }
  }

  void _attachImage() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from library'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send({String? retry}) async {
    final message = retry ?? _composerController.text.trim();
    final image = retry == null ? _pendingImage : null;
    if ((message.isEmpty && image == null) || _sending) return;

    final window = _store.wireTurns();
    setState(() {
      _sending = true;
      if (retry == null) {
        _composerController.clear();
        _pendingImage = null;
      }
    });

    String imagePath = '';
    String? imageUrl;
    try {
      if (image != null) {
        final up = await _chat.uploadChatImage(image);
        imagePath = up.storagePath;
        imageUrl = up.downloadUrl;
      }
    } catch (_) {
      if (mounted) {
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't upload that image.")),
        );
      }
      return;
    }

    if (retry == null) {
      _store.addTurn(TurnRole.user, message, TurnSource.text,
          imageUrl: imageUrl);
    } else if (window.isNotEmpty &&
        window.last['role'] == 'user' &&
        window.last['text'] == message) {
      // Retrying: the failed turn is already the tail of the window — drop it
      // so it isn't sent twice (once as history, once as `message`).
      window.removeLast();
    }

    final wireMessage = message.isEmpty ? '(shared a photo)' : message;
    _store.addPending('Thinking…');
    try {
      ChatResult? result;
      try {
        await for (final ev in _api.chatStream(
          wireMessage,
          sessionId: _sessionId,
          viewingProfileUid: widget.viewingProfileUid,
          recentTurns: window,
          imagePath: imagePath,
        )) {
          if (!mounted) return;
          if (ev is ChatStatus) {
            _store.updatePendingText(ev.label);
          } else if (ev is ChatReplyEvent) {
            result = ev.result;
          }
        }
      } on ApiException {
        // Stream unavailable (proxy, old build) — fall back to the plain call.
        result = await _api.chat(
          wireMessage,
          sessionId: _sessionId,
          viewingProfileUid: widget.viewingProfileUid,
          recentTurns: window,
          imagePath: imagePath,
        );
      }
      if (!mounted) return;
      if (result == null) {
        _store.dropPending();
        throw const _NoReply();
      }
      _store.resolvePending(result.reply, tools: result.toolsUsed);
      if (result.imageRejected) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That image was blocked by our check.')),
        );
      }
      if (result.fallbackForm) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Let’s finish the basics on a quick form.'),
            action: SnackBarAction(
              label: 'Open',
              onPressed: () => context.go('/settings/profile'),
            ),
          ),
        );
      }
    } on ApiException {
      // Transient failure — don't leave a stuck "thinking" turn.
      if (!mounted) return;
      _store.dropPending();
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: const Text("Couldn't reach Ayma. Check your connection."),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _send(retry: message),
            ),
          ),
        );
    } catch (_) {
      if (!mounted) return;
      _store.dropPending();
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: const Text('Something went wrong sending that message.'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _send(retry: message),
            ),
          ),
        );
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _composerFocus.requestFocus();
      }
    }
  }

  late final ProfileService _profiles =
      widget.profileService ?? ProfileService();

  Future<void> _getStarted() async {
    try {
      await _profiles.markOnboardingStarted();
    } catch (_) {
      // Non-fatal — the server also derives `interview` from other signals.
    }
    if (mounted) context.go(PreboardingFlowScreen.path);
  }

  String _voiceCaption() => switch (_voice.phase) {
        VoiceSessionPhase.idle => 'Tap the mic to talk',
        VoiceSessionPhase.connecting => 'Connecting…',
        VoiceSessionPhase.error => _voice.errorMessage ?? 'Voice error',
        VoiceSessionPhase.live => _voice.agentSpeaking
            ? 'Ayma is speaking'
            : (_voice.muted ? 'Mic muted — tap to unmute' : 'Listening'),
      };

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            AymaScreenHeader(
              eyebrow: 'Your matchmaker',
              title: 'Ayma',
              titleSize: 34,
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
              action: widget.marketing
                  ? TextButton(
                      onPressed: _getStarted,
                      child: const Text('Get started'),
                    )
                  : const NotificationBellButton(),
            ),
            ListenableBuilder(
              listenable: _voice,
              builder: (context, _) {
                if (_voice.phase == VoiceSessionPhase.idle) {
                  return const SizedBox(height: 4);
                }
                final err = _voice.phase == VoiceSessionPhase.error;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 5,
                        height: 5,
                        margin: const EdgeInsets.only(right: 8, top: 3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: err ? AymaColors.error : ac.accent,
                        ),
                      ),
                      Flexible(
                        child: Text(
                          _voiceCaption().toUpperCase(),
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: AymaType.mono(
                            size: 9,
                            color: err ? AymaColors.error : ac.fgDim,
                          ).copyWith(letterSpacing: 1.8),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: _store,
                builder: (context, _) {
                  final turns = _store.turns;
                  if (turns.isEmpty) {
                    if (_loadingHistory) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (_historyError != null) {
                      return Center(
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 40),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _historyError!,
                                textAlign: TextAlign.center,
                                style: AymaType.sans(
                                    size: 15, soft: true, color: ac.fgMute),
                              ),
                              const SizedBox(height: 12),
                              TextButton(
                                onPressed: _retryHistory,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                          'Say hello to start a conversation.',
                          textAlign: TextAlign.center,
                          style: AymaType.sans(
                              size: 15, soft: true, color: ac.fgMute),
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    itemCount: turns.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return const DividerLabel("Your conversation");
                      }
                      final idx = i - 1;
                      final t = turns[idx];
                      return _TranscriptLine(
                        turn: t,
                        latest: idx == turns.length - 1,
                        api: _api,
                        onThumbsDown: (t.role == TurnRole.ayma &&
                                t.isFinal &&
                                t.text.isNotEmpty)
                            ? () => _api.submitFeedback(
                                  category: 'thumbs_down',
                                  quote: t.text,
                                  sessionId: _sessionId,
                                )
                            : null,
                      );
                    },
                  );
                },
              ),
            ),
            // Live status ("Searching the web…") rides on the pending Ayma
            // turn now, so there's no separate "thinking" line here.
            ListenableBuilder(
              listenable: _voice,
              builder: (context, _) => _Composer(
                controller: _composerController,
                focusNode: _composerFocus,
                canSend: (_canSend || _pendingImage != null) && !_sending,
                onSend: _send,
                onAttach: _attachImage,
                pendingImage: _pendingImage,
                onClearImage: () => setState(() => _pendingImage = null),
                voicePhase: _voice.phase,
                muted: _voice.muted,
                onVoiceTap: _toggleVoice,
                onMuteTap: _voice.toggleMute,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The stream ended with no reply event — treated like any transient failure.
class _NoReply implements Exception {
  const _NoReply();
}

/// One transcript turn as a labelled line — no bubble. Ayma speaks in serif
/// italic; you answer in sans. Anything but the latest turn is dimmed. Ayma's
/// lines carry a one-tap thumbs-down that logs conversational feedback (§15).
/// Marks the end of an Ayma turn that carries a stored report, e.g.
/// `…take a look. [face_report:abc123]`. Stripped from the shown text; drives
/// the "View report" button.
final _reportMarker =
    RegExp(r'\s*\[(face|body)_report:([A-Za-z0-9_-]+)\]\s*$');

class _TranscriptLine extends StatefulWidget {
  const _TranscriptLine({
    required this.turn,
    required this.latest,
    this.api,
    this.onThumbsDown,
  });

  final TranscriptTurn turn;
  final bool latest;

  /// Used to fetch a stored report when the turn carries a `[*_report:id]`
  /// marker. Null in tests that don't exercise that path.
  final ApiClient? api;

  /// Non-null only for a finished Ayma line — fire-and-forget feedback.
  final Future<void> Function()? onThumbsDown;

  @override
  State<_TranscriptLine> createState() => _TranscriptLineState();
}

class _TranscriptLineState extends State<_TranscriptLine> {
  bool _flagged = false;

  Future<void> _thumbsDown() async {
    if (_flagged) return;
    setState(() => _flagged = true);
    try {
      await widget.onThumbsDown!();
    } catch (_) {
      if (mounted) setState(() => _flagged = false);
    }
  }

  Widget _photo(BuildContext context, {required bool rounded}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(rounded ? 14 : 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.62,
        ),
        child: Image.network(
          widget.turn.imageUrl!,
          fit: BoxFit.cover,
          loadingBuilder: (c, w, p) => p == null
              ? w
              : const SizedBox(
                  height: 160,
                  width: 160,
                  child: Center(child: CircularProgressIndicator()),
                ),
          errorBuilder: (c, e, s) => const SizedBox(
            height: 60,
            child: Center(child: Icon(Icons.broken_image_outlined)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final turn = widget.turn;
    final isAyma = turn.role == TurnRole.ayma;
    final hasImage = turn.imageUrl != null;
    final width = MediaQuery.of(context).size.width;

    if (!isAyma) {
      // You — a right-aligned rounded bubble (Gemini style).
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width * 0.82),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (hasImage)
                  Padding(
                    padding: EdgeInsets.only(bottom: turn.text.isEmpty ? 0 : 6),
                    child: _photo(context, rounded: true),
                  ),
                if (turn.text.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: ac.accentFaint,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                    child: Text(
                      turn.text,
                      style: AymaType.sans(
                          size: 15, color: ac.fg, height: 1.4),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // Ayma — full-width, no bubble; serif italic; markdown headers/lists.
    // A finished turn may end with a `[face_report:id]` / `[body_report:id]`
    // marker: strip it from the shown text and offer a "View report" button.
    final marker = turn.isFinal ? _reportMarker.firstMatch(turn.text) : null;
    final displayText =
        marker != null ? turn.text.replaceFirst(_reportMarker, '') : turn.text;
    final reportKind = marker?.group(1);
    final reportId = marker?.group(2);

    return Opacity(
      opacity: widget.latest || !turn.isFinal ? 1 : 0.62,
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (turn.tools.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome, size: 12, color: ac.accent),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        turn.tools.join('  ·  ').toUpperCase(),
                        style: AymaType.mono(size: 9, color: ac.fgMute)
                            .copyWith(letterSpacing: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            if (hasImage)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _photo(context, rounded: false),
              ),
            if (!turn.isFinal)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: ac.fgMute),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      turn.text,
                      style: AymaType.serif(
                        size: 18, italic: true, color: ac.fgDim,
                      ).copyWith(height: 1.3),
                    ),
                  ),
                ],
              )
            else if (displayText.isNotEmpty)
              MarkdownText(
                displayText,
                style: AymaType.serif(size: 19, italic: true, color: ac.fg)
                    .copyWith(height: 1.4),
                linkColor: ac.accent,
              ),
            if (reportKind != null && reportId != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  onPressed: () {
                    if (reportKind == 'face') {
                      openStoredFaceReport(context,
                          api: widget.api, reportId: reportId);
                    } else {
                      openStoredBodyReport(context,
                          api: widget.api, reportId: reportId);
                    }
                  },
                  icon: const Icon(Icons.assessment_outlined, size: 16),
                  label: const Text('View report'),
                ),
              ),
            if (widget.onThumbsDown != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InkWell(
                  onTap: _flagged ? null : _thumbsDown,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _flagged
                              ? Icons.thumb_down_alt
                              : Icons.thumb_down_alt_outlined,
                          size: 13,
                          color: _flagged ? ac.accent : ac.fgMute,
                        ),
                        if (_flagged) ...[
                          const SizedBox(width: 6),
                          Text('noted',
                              style: AymaType.mono(size: 8, color: ac.fgMute)
                                  .copyWith(letterSpacing: 1.5)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.canSend,
    required this.onSend,
    required this.onAttach,
    required this.pendingImage,
    required this.onClearImage,
    required this.voicePhase,
    required this.muted,
    required this.onVoiceTap,
    required this.onMuteTap,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final File? pendingImage;
  final VoidCallback onClearImage;
  final VoiceSessionPhase voicePhase;
  final bool muted;
  final Future<void> Function() onVoiceTap;
  final Future<void> Function() onMuteTap;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final voiceActive = voicePhase == VoiceSessionPhase.connecting ||
        voicePhase == VoiceSessionPhase.live;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: ac.bg,
          border: Border(top: BorderSide(color: ac.lineSoft, width: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pendingImage != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 4),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(pendingImage!,
                            width: 56, height: 56, fit: BoxFit.cover),
                      ),
                      Positioned(
                        top: -8,
                        right: -8,
                        child: IconButton(
                          onPressed: onClearImage,
                          iconSize: 18,
                          icon: const Icon(Icons.cancel),
                          color: ac.fgMute,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: () => onVoiceTap(),
                  tooltip: voiceActive ? 'End voice' : 'Talk to Ayma',
                  icon: Icon(
                    voiceActive ? Icons.stop_rounded : Icons.mic_none_rounded,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: voiceActive ? ac.accent : ac.bgElev,
                    foregroundColor:
                        voiceActive ? AymaColors.onAccent : ac.fgDim,
                  ),
                ),
                if (voicePhase == VoiceSessionPhase.live) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () => onMuteTap(),
                    tooltip: muted ? 'Unmute' : 'Mute',
                    icon: Icon(
                      muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                    ),
                    style: IconButton.styleFrom(foregroundColor: ac.fgDim),
                  ),
                ],
                if (!voiceActive)
                  IconButton(
                    onPressed: onAttach,
                    tooltip: 'Attach a photo',
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    style: IconButton.styleFrom(foregroundColor: ac.fgDim),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(
                      hintText: 'Message Ayma',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: canSend ? onSend : null,
                  icon: const Icon(Icons.arrow_upward_rounded),
                  style: IconButton.styleFrom(
                    backgroundColor: canSend ? ac.accent : ac.bgElev,
                    foregroundColor:
                        canSend ? AymaColors.onAccent : ac.fgMute,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
