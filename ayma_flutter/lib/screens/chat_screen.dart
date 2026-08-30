import 'package:flutter/material.dart';

import '../theme.dart';

/// Ayma chat screen — shell only (Step 8).
///
/// Empty transcript view + a composer (text field + send). No backend wiring
/// yet: Step 9 adds a canned `/chat` echo, Step 10 real Gemini replies, and the
/// full voice/transcript interface (§1) comes across Phase 2.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  static const path = '/chat';

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _composerController = TextEditingController();
  final _composerFocus = FocusNode();
  bool _canSend = false;

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
    super.dispose();
  }

  void _send() {
    // Wired in Step 9 (canned reply) / Step 10 (real Gemini).
    _composerController.clear();
    _composerFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Ayma')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'Say hello to start a conversation.',
                  textAlign: TextAlign.center,
                  style: AymaType.sans(size: 15, soft: true, color: ac.fgMute),
                ),
              ),
            ),
          ),
          _Composer(
            controller: _composerController,
            focusNode: _composerFocus,
            canSend: _canSend,
            onSend: _send,
          ),
        ],
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
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool canSend;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        decoration: BoxDecoration(
          color: ac.bg,
          border: Border(top: BorderSide(color: ac.lineSoft, width: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
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
