import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_client.dart';
import '../services/chat_service.dart';
import '../services/ids.dart';
import '../services/profile_service.dart';
import '../services/transcript_store.dart';
import '../services/voice_session_controller.dart';
import '../theme.dart';
import '../widgets/notification_bell.dart';
import 'preboarding_flow_screen.dart';

/// Ayma chat screen. One [TranscriptStore] backs the view; typed turns and
/// relayed voice-transcript segments flow into it through the same path, so a
/// voice turn renders exactly like a typed one (§1.6, Steps 8–16).
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
    } catch (_) {
      // Offline / first run — start with an empty thread.
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
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

    try {
      final result = await _api.chat(
        message.isEmpty ? '(shared a photo)' : message,
        sessionId: _sessionId,
        viewingProfileUid: widget.viewingProfileUid,
        recentTurns: window,
        imagePath: imagePath,
      );
      if (!mounted) return;
      _store.addTurn(TurnRole.ayma, result.reply, TurnSource.text);
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
      // Transient failure — don't pollute the transcript with a fake Ayma
      // reply. Surface it as a dismissible notice with a one-tap retry.
      if (!mounted) return;
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

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayma'),
        actions: widget.marketing
            ? [
                TextButton(
                  onPressed: _getStarted,
                  child: const Text('Get started'),
                ),
              ]
            : const [NotificationBellButton()],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: _store,
              builder: (context, _) {
                final turns = _store.turns;
                if (turns.isEmpty) {
                  if (_loadingHistory) {
                    return const Center(child: CircularProgressIndicator());
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
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  itemCount: turns.length,
                  itemBuilder: (context, i) => _Bubble(turn: turns[i]),
                );
              },
            ),
          ),
          if (_sending)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('Ayma is typing…',
                  style: AymaType.sans(size: 12, color: ac.fgMute)),
            ),
          ListenableBuilder(
            listenable: _voice,
            builder: (context, _) => _VoiceStatusStrip(voice: _voice),
          ),
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
    );
  }
}

class _VoiceStatusStrip extends StatelessWidget {
  const _VoiceStatusStrip({required this.voice});
  final VoiceSessionController voice;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final (String label, Color color)? content = switch (voice.phase) {
      VoiceSessionPhase.connecting => ('Connecting to Ayma…', ac.fgMute),
      VoiceSessionPhase.live => voice.agentSpeaking
          ? ('Ayma is speaking', ac.accent)
          : (voice.muted ? 'Mic muted — tap to unmute' : 'Listening…', ac.fg),
      VoiceSessionPhase.error => (
          voice.errorMessage ?? 'Voice error',
          AymaColors.error,
        ),
      VoiceSessionPhase.idle => null,
    };
    if (content == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: ac.bgCard,
      child: Text(
        content.$1,
        style: AymaType.sans(size: 12, color: content.$2),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});
  final TranscriptTurn turn;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isUser = turn.role == TurnRole.user;
    final hasImage = turn.imageUrl != null;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: EdgeInsets.all(hasImage ? 6 : 0).add(
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isUser ? ac.accentSoft : ac.bgCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasImage)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  turn.imageUrl!,
                  fit: BoxFit.cover,
                  loadingBuilder: (c, w, p) => p == null
                      ? w
                      : const SizedBox(
                          height: 160,
                          width: 160,
                          child: Center(child: CircularProgressIndicator())),
                  errorBuilder: (c, e, s) => const SizedBox(
                    height: 60,
                    child: Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              ),
            if (turn.text.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(6, hasImage ? 8 : 6, 6, 6),
                child: Text(
                  turn.text,
                  style: AymaType.sans(
                    size: 15,
                    color: turn.isFinal ? ac.fg : ac.fgDim,
                    height: 1.4,
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
                    backgroundColor: voiceActive ? ac.accent : ac.bgCard,
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
                    backgroundColor: canSend ? ac.accent : ac.bgCard,
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
