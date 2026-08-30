import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/voice_session_controller.dart';
import '../theme.dart';

enum _Role { user, ayma }

class _Turn {
  const _Turn(this.role, this.text);
  final _Role role;
  final String text;
}

/// Ayma chat screen (Step 8 shell + Step 9 canned `/chat` round-trip + Step 14
/// voice session).
///
/// Voice and text turns are still separate lists — the unified voice/text
/// transcript store (§1.6) lands in Step 16.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.apiClient, this.voiceController});

  static const path = '/chat';

  final ApiClient? apiClient;
  final VoiceSessionController? voiceController;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ApiClient _api = widget.apiClient ?? ApiClient();
  late final VoiceSessionController _voice =
      widget.voiceController ?? VoiceSessionController();
  final _composerController = TextEditingController();
  final _composerFocus = FocusNode();
  final _scrollController = ScrollController();
  final List<_Turn> _turns = [];
  bool _canSend = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _composerController.addListener(() {
      final canSend = _composerController.text.trim().isNotEmpty;
      if (canSend != _canSend) setState(() => _canSend = canSend);
    });
  }

  @override
  void dispose() {
    _composerController.dispose();
    _composerFocus.dispose();
    _scrollController.dispose();
    if (widget.voiceController == null) _voice.dispose();
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

  Future<void> _send() async {
    final message = _composerController.text.trim();
    if (message.isEmpty || _sending) return;

    setState(() {
      _turns.add(_Turn(_Role.user, message));
      _sending = true;
      _composerController.clear();
    });
    _scrollToBottom();

    try {
      final reply = await _api.chat(message);
      if (!mounted) return;
      setState(() => _turns.add(_Turn(_Role.ayma, reply)));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _turns.add(_Turn(_Role.ayma, 'Something went wrong (${e.message}).')));
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _composerFocus.requestFocus();
        _scrollToBottom();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Ayma')),
      body: Column(
        children: [
          Expanded(
            child: _turns.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        'Say hello to start a conversation.',
                        textAlign: TextAlign.center,
                        style: AymaType.sans(
                            size: 15, soft: true, color: ac.fgMute),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    itemCount: _turns.length,
                    itemBuilder: (context, i) => _Bubble(turn: _turns[i]),
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
              canSend: _canSend && !_sending,
              onSend: _send,
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
  final _Turn turn;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isUser = turn.role == _Role.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isUser ? ac.accentSoft : ac.bgCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Text(turn.text,
            style: AymaType.sans(size: 15, color: ac.fg, height: 1.4)),
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
    required this.voicePhase,
    required this.muted,
    required this.onVoiceTap,
    required this.onMuteTap,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool canSend;
  final VoidCallback onSend;
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              onPressed: () => onVoiceTap(),
              tooltip: voiceActive ? 'End voice' : 'Talk to Ayma',
              icon: Icon(
                voiceActive
                    ? Icons.stop_rounded
                    : Icons.mic_none_rounded,
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
                foregroundColor: canSend ? AymaColors.onAccent : ac.fgMute,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
